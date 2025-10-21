pub fn minI32(a: i32, b: i32) i32 {
    return if (a < b) a else b;
}

pub fn maxI32(a: i32, b: i32) i32 {
    return if (a > b) a else b;
}

pub fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    return maxI32(min_value, minI32(max_value, value));
}

pub fn lineIntersectionX(x1: i32, y1: i32, x2: i32, y2: i32, y: i32) i32 {
    if (y1 == y2) return x1;

    const dy = y2 - y1;
    const dx = x2 - x1;
    const t_num = y - y1;
    return x1 + @divTrunc(t_num * dx, dy);
}
