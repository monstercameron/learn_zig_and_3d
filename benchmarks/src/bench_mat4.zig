const std = @import("std");
const math = @import("../../src/math.zig");

pub fn benchmarkMat4Multiply(iterations: u64) u64 {
    var m1 = math.Mat4.identity();
    const m2 = math.Mat4.rotateY(0.1);
    var m_result = math.Mat4.identity();

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        m_result = math.Mat4.multiply(m1, m2);
        m1.data[0] += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}

pub fn benchmarkMat4MulVec4(iterations: u64) u64 {
    var m = math.Mat4.identity();
    const v = math.Vec4.new(1.0, 2.0, 3.0, 1.0);
    var v_result = math.Vec4.new(0.0, 0.0, 0.0, 0.0);

    var timer = std.time.Timer.init();
    timer.start();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        v_result = math.Mat4.mulVec4(m, v);
        m.data[0] += 0.00001; // Prevent compiler from optimizing away the loop
    }
    timer.stop();
    return timer.read();
}
