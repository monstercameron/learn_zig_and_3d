import re

def process_file():
    with open("src/renderer.zig", "r", encoding="utf-8") as f:
        text = f.read()

    old_func = """    fn applySkyboxPass(
        self: *Renderer,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) void {
        const hdri = self.hdri_map orelse return;
        const pass_start = std.time.nanoTimestamp();

        const height: usize = @intCast(self.bitmap.height);

        // Instead of multi-threading immediately, let's just do it sequentially
        // to see if threading was the issue!
        var ctx = SkyboxJobContext{
            .renderer = self,
            .right = basis_right,
            .up = basis_up,
            .forward = basis_forward,
            .projection = projection,
            .hdri_map = &hdri,
            .start_row = 0,
            .end_row = height,
        };
        applySkyboxRows(&ctx);
        self.recordRenderPassTiming("skybox", pass_start);
    }"""

    new_func = """    fn applySkyboxPass(
        self: *Renderer,
        basis_right: math.Vec3,
        basis_up: math.Vec3,
        basis_forward: math.Vec3,
        projection: ProjectionParams,
    ) void {
        const hdri_map = self.hdri_map orelse return;
        const pass_start = std.time.nanoTimestamp();
        const height: usize = @intCast(self.bitmap.height);

        const stripe_count = computeStripeCount(self.skybox_job_contexts.len, height);
        const rows_per_job = if (stripe_count <= 1) height else (height + stripe_count - 1) / stripe_count;

        if (stripe_count <= 1 or self.job_system == null) {
            var ctx = SkyboxJobContext{
                .renderer = self,
                .right = basis_right,
                .up = basis_up,
                .forward = basis_forward,
                .projection = projection,
                .hdri_map = &hdri_map,
                .start_row = 0,
                .end_row = height,
            };
            applySkyboxRows(&ctx);
            self.recordRenderPassTiming("skybox", pass_start);
            return;
        }

        var parent_job = Job.init(noopRenderPassJob, @ptrCast(self), null);
        var stripe_index: usize = 0;
        while (stripe_index < stripe_count) : (stripe_index += 1) {
            const start_row = stripe_index * rows_per_job;
            if (start_row >= height) break;
            const end_row = @min(height, start_row + rows_per_job);

            self.skybox_job_contexts[stripe_index] = .{
                .renderer = self,
                .right = basis_right,
                .up = basis_up,
                .forward = basis_forward,
                .projection = projection,
                .hdri_map = &hdri_map,
                .start_row = start_row,
                .end_row = end_row,
            };

            self.color_grade_jobs[stripe_index] = Job.init(
                runSkyboxJobWrapper,
                @ptrCast(&self.skybox_job_contexts[stripe_index]),
                &parent_job,
            );
            if (!self.job_system.?.submitJobAuto(&self.color_grade_jobs[stripe_index])) {
                runSkyboxJobWrapper(@ptrCast(&self.skybox_job_contexts[stripe_index]));
            }
        }

        runSkyboxJobWrapper(@ptrCast(&self.skybox_job_contexts[0]));
        parent_job.complete();
        parent_job.wait();
        self.recordRenderPassTiming("skybox", pass_start);
    }"""

    text = text.replace(old_func, new_func)

    with open("src/renderer.zig", "w", encoding="utf-8") as f:
        f.write(text)

process_file()
