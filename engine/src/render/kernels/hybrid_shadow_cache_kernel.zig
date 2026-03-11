pub fn clearUnknown(cache: []u8) void {
    @memset(cache, 0xFF);
}
