//! # Job System Module
//!
//! This module implements a work-stealing job system for parallel execution.
//! Jobs are independent work units that can be executed on any thread.
//!
//! **Key Concepts**:
//! - Job: Function pointer + data payload
//! - Job Queue: Lock-free MPMC queue for work distribution
//! - Worker Threads: Pool of threads that execute jobs
//! - Work Stealing: Idle threads can steal work from busy threads
//!
//! **Architecture**:
//! ```
//! Main Thread                Worker Threads (N-1)
//!     |                           |
//!     v                           v
//! [Submit Jobs] -------> [Job Queue] <------- [Steal Work]
//!     |                           |
//!     v                           v
//! [Wait/Sync]            [Execute Jobs]
//! ```

const std = @import("std");
const builtin = @import("builtin");

// ========== JOB STRUCTURE ==========

/// Job function signature - takes context pointer as parameter
pub const JobFn = *const fn (ctx: *anyopaque) void;

/// A job represents a unit of work that can be executed on any thread
pub const Job = struct {
    /// Function to execute
    function: JobFn,
    /// Opaque pointer to job-specific data
    context: *anyopaque,
    /// Parent job (for dependency tracking, null if top-level)
    parent: ?*Job,
    /// Number of unfinished child jobs (atomic counter)
    unfinished_jobs: std.atomic.Value(u32),

    /// Create a new job
    pub fn init(function: JobFn, context: *anyopaque, parent: ?*Job) Job {
        return Job{
            .function = function,
            .context = context,
            .parent = parent,
            .unfinished_jobs = std.atomic.Value(u32).init(1),
        };
    }

    /// Execute this job
    pub fn execute(self: *Job) void {
        self.function(self.context);
        self.finish();
    }

    /// Mark job as finished and propagate to parent
    fn finish(self: *Job) void {
        // Decrement unfinished counter
        const unfinished = self.unfinished_jobs.fetchSub(1, .release);

        // If this was the last unfinished job (counter was 1, now 0)
        if (unfinished == 1) {
            // Propagate completion to parent
            if (self.parent) |parent| {
                parent.finish();
            }
        }
    }

    /// Check if job and all children are complete
    pub fn isComplete(self: *const Job) bool {
        return self.unfinished_jobs.load(.acquire) == 0;
    }

    /// Wait for job to complete (spin wait)
    pub fn wait(self: *const Job) void {
        while (!self.isComplete()) {
            // Yield CPU to other threads
            std.atomic.spinLoopHint();
        }
    }
};

// ========== JOB QUEUE (LOCK-FREE MPMC) ==========

/// Multi-producer multi-consumer job deque guarded by a mutex.
/// Workers pop from the bottom (LIFO) while thieves steal from the top (FIFO).
pub const JobQueue = struct {
    /// Circular buffer storing job pointers
    jobs: []?*Job,
    /// Total capacity of the buffer
    capacity: u32,
    /// Index of the next element to remove from the top (steal side)
    head: u32,
    /// Index of the next free slot at the bottom (push/pop side)
    tail: u32,
    /// Number of jobs currently stored
    len: u32,
    /// Mutex protecting queue mutations
    mutex: std.Thread.Mutex,
    /// Allocator for queue memory
    allocator: std.mem.Allocator,

    /// Create a new job queue
    pub fn init(capacity: u32, allocator: std.mem.Allocator) !JobQueue {
        if (capacity == 0) return error.InvalidCapacity;

        const jobs = try allocator.alloc(?*Job, capacity);
        @memset(jobs, null);

        return JobQueue{
            .jobs = jobs,
            .capacity = capacity,
            .head = 0,
            .tail = 0,
            .len = 0,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    /// Clean up queue
    pub fn deinit(self: *JobQueue) void {
        self.allocator.free(self.jobs);
    }

    /// Push a job onto the queue (any producer thread)
    pub fn push(self: *JobQueue, job: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == self.capacity) {
            return false;
        }

        self.jobs[self.tail] = job;
        self.tail = (self.tail + 1) % self.capacity;
        self.len += 1;
        return true;
    }

    /// Pop a job from the queue (worker owning this deque)
    pub fn pop(self: *JobQueue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0) {
            return null;
        }

        self.tail = (self.tail + self.capacity - 1) % self.capacity;
        const job = self.jobs[self.tail];
        self.jobs[self.tail] = null;
        self.len -= 1;
        return job;
    }

    /// Steal a job from the queue (thief threads)
    pub fn steal(self: *JobQueue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0) {
            return null;
        }

        const job = self.jobs[self.head];
        self.jobs[self.head] = null;
        self.head = (self.head + 1) % self.capacity;
        self.len -= 1;
        return job;
    }

    /// Get number of jobs in queue (approximate)
    pub fn count(self: *const JobQueue) u32 {
        const queue = @constCast(self);
        queue.mutex.lock();
        defer queue.mutex.unlock();
        return queue.len;
    }
};

// ========== WORKER THREAD ==========

/// Worker thread that executes jobs from the queue
const WorkerThread = struct {
    /// Thread handle
    thread: std.Thread,
    /// Worker's local job queue
    queue: JobQueue,
    /// Reference to parent job system
    system: *JobSystem,
    /// Worker ID
    id: u32,
    /// Should worker continue running
    running: std.atomic.Value(bool),

    /// Worker thread main loop
    fn run(self: *WorkerThread) void {
        // std.debug.print("Worker {} starting...\n", .{self.id});
        // var jobs_executed: usize = 0;
        var iterations: usize = 0;

        while (self.running.load(.acquire)) {
            iterations += 1;

            // Try to get a job from our local queue
            var job = self.queue.pop();

            // if (iterations <= 5 or (iterations % 10000 == 0)) {
            //     const q_count = self.queue.count();
            //     std.debug.print("Worker {} iter {}: queue has {} jobs, pop result: {}\n", .{self.id, iterations, q_count, job != null});
            // }

            // If no local work, try to steal from other workers
            if (job == null) {
                job = self.system.stealJob(self.id);
            }

            if (job) |j| {
                // Execute the job
                j.execute();
            } else {
                // No work available - yield CPU
                std.Thread.yield() catch {};
            }
        }
    }
};

// ========== JOB SYSTEM ==========

/// Main job system - manages worker threads and job distribution
pub const JobSystem = struct {
    /// Worker threads
    workers: []WorkerThread,
    /// Number of worker threads
    worker_count: u32,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Is system running
    running: std.atomic.Value(bool),
    /// Round-robin counter for job submission
    next_worker: std.atomic.Value(u32),

    /// Initialize job system with N-1 worker threads (leave 1 core for main thread)
    pub fn init(allocator: std.mem.Allocator) !*JobSystem {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        // TEMPORARY: Force single worker for testing
        const worker_count: u32 = 1;
        // const worker_count = if (cpu_count > 1) @as(u32, @intCast(cpu_count - 1)) else 1;

        std.debug.print("Job System: Detected {} CPUs, creating {} worker thread(s) [TESTING MODE]\n", .{ cpu_count, worker_count });

        const workers = try allocator.alloc(WorkerThread, worker_count);
        errdefer allocator.free(workers);

        // Allocate system on heap to get stable pointer
        const system = try allocator.create(JobSystem);
        errdefer allocator.destroy(system);

        system.* = JobSystem{
            .workers = workers,
            .worker_count = worker_count,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .next_worker = std.atomic.Value(u32).init(0),
        };

        // Initialize worker threads
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerThread{
                .thread = undefined, // Will be set when thread starts
                .queue = try JobQueue.init(1024, allocator),
                .system = system,
                .id = @intCast(i),
                .running = std.atomic.Value(bool).init(true),
            };
        }

        // Start worker threads
        for (workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker});
        }

        return system;
    }

    /// Shut down job system and wait for all threads
    pub fn deinit(self: *JobSystem) void {
        const allocator = self.allocator;

        // Signal all workers to stop
        self.running.store(false, .release);
        for (self.workers) |*worker| {
            worker.running.store(false, .release);
        }

        // Wait for all threads to finish
        for (self.workers) |*worker| {
            worker.thread.join();
            worker.queue.deinit();
        }

        allocator.free(self.workers);
        allocator.destroy(self);
    }

    /// Submit a job to a specific worker queue
    pub fn submitJob(self: *JobSystem, job: *Job, worker_id: u32) bool {
        const worker_index = worker_id % self.worker_count;
        return self.workers[worker_index].queue.push(job);
    }

    /// Submit a job to the least busy worker
    pub fn submitJobAuto(self: *JobSystem, job: *Job) bool {
        // Try submitting to each worker in round-robin until one accepts
        var attempts: u32 = 0;
        while (attempts < self.worker_count) : (attempts += 1) {
            const worker_idx = (self.next_worker.fetchAdd(1, .monotonic)) % self.worker_count;
            const result = self.workers[worker_idx].queue.push(job);
            if (result) {
                return true;
            }
        }

        std.debug.print("ERROR: Failed to submit job after trying all {} workers\n", .{self.worker_count});
        return false;
    }

    /// Try to steal a job from another worker (for work stealing)
    fn stealJob(self: *JobSystem, worker_id: u32) ?*Job {
        // Try to steal from each worker in round-robin order
        // Start from the next worker to avoid checking ourselves
        var i: u32 = 1;
        while (i < self.worker_count) : (i += 1) {
            const target = (worker_id + i) % self.worker_count;
            // Double-check bounds to prevent race conditions
            if (target >= self.worker_count) continue;
            if (self.workers[target].queue.steal()) |job| {
                return job;
            }
        }
        return null;
    }

    /// Get total number of pending jobs across all queues
    pub fn pendingJobs(self: *const JobSystem) u32 {
        var total: u32 = 0;
        for (self.workers) |*worker| {
            total += worker.queue.count();
        }
        return total;
    }
};

// ========== HELPER FUNCTIONS ==========

/// Allocate a job on the heap
pub fn allocateJob(allocator: std.mem.Allocator, function: JobFn, context: *anyopaque, parent: ?*Job) !*Job {
    const job = try allocator.create(Job);
    job.* = Job.init(function, context, parent);
    return job;
}

/// Free a heap-allocated job
pub fn freeJob(allocator: std.mem.Allocator, job: *Job) void {
    allocator.destroy(job);
}
