//! Pass Dispatch module.
//! Render pipeline graph/registry/dispatch definitions for pass execution order and toggles.

/// Computes rows per stripe.
/// Keeps compute rows per stripe as the single implementation point so call-site behavior stays consistent.
pub fn computeRowsPerStripe(stripe_count: usize, height: usize) usize {
    if (stripe_count <= 1) return height;
    return (height + stripe_count - 1) / stripe_count;
}
