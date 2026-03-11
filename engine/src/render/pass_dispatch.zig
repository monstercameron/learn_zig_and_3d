pub fn computeRowsPerStripe(stripe_count: usize, height: usize) usize {
    if (stripe_count <= 1) return height;
    return (height + stripe_count - 1) / stripe_count;
}
