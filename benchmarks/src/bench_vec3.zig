const std = @import("std");
const math = @import("../../src/math.zig");

pub fn benchmarkVec3Add(iterations: u64) u64 {
    var v1 = math.Vec3.new(1.0, 2.0, 3.0);
    const v2 = math.Vec3.new(4.0, 5.0, 6.0);
    var v_result = math.Vec3.new(0.0, 0.0, 0.0);

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        v_result = math.Vec3.add(v1, v2);
        v1.x += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}

pub fn benchmarkVec3Sub(iterations: u64) u64 {
    var v1 = math.Vec3.new(1.0, 2.0, 3.0);
    const v2 = math.Vec3.new(4.0, 5.0, 6.0);
    var v_result = math.Vec3.new(0.0, 0.0, 0.0);

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        v_result = math.Vec3.sub(v1, v2);
        v1.x += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}

pub fn benchmarkVec3Scale(iterations: u64) u64 {
    var v1 = math.Vec3.new(1.0, 2.0, 3.0);
    const s = 2.5;
    var v_result = math.Vec3.new(0.0, 0.0, 0.0);

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        v_result = math.Vec3.scale(v1, @as(f32, s));
        v1.x += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}

pub fn benchmarkVec3Dot(iterations: u64) u64 {
    var v1 = math.Vec3.new(1.0, 2.0, 3.0);
    const v2 = math.Vec3.new(4.0, 5.0, 6.0);
    var dot_result: f32 = 0.0;

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        dot_result = math.Vec3.dot(v1, v2);
        v1.x += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}

pub fn benchmarkVec3Cross(iterations: u64) u64 {
    var v1 = math.Vec3.new(1.0, 2.0, 3.0);
    const v2 = math.Vec3.new(4.0, 5.0, 6.0);
    var v_result = math.Vec3.new(0.0, 0.0, 0.0);

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        v_result = math.Vec3.cross(v1, v2);
        v1.x += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}
