# Water simulation notes

The Today tab's bottle runs a 2D Position-Based Fluids (PBF) simulation
(`App/HidrateTestApp/Wave/FluidSimulation.swift`).

## What is physical

* Incompressibility: density is enforced as a per-particle constraint each substep, the
  defining property of liquid water.
* Gravity: the device's real gravity vector (CoreMotion), 9.81 m/s², converted to points
  with a scale set by the bottle's real height (interior ≈ 20 cm). This fixes slosh
  frequencies and fall speeds without tuning. Because the app is portrait-locked, raw
  device axes map straight to the screen, so 90° and 180° turns are represented fully.
* Viscosity: a small XSPH smoothing, water-like. Surface tension is only approximated by
  the short-range anti-clumping term.
* Walls: a signed-distance field sampled from the drawn silhouette, with inelastic contact.

## What is numerical (and how it was chosen)

A headless harness (`swiftc -O` of the simulation plus a `main.swift`) fills a vessel to
60% and checks, under gravity: no NaNs, every particle inside the wall radius, mean
density within a few percent of rest, a flat free surface, a splash that peaks and then
calms, and correct pooling when gravity is rotated 90° and 180°. Two findings drove the
settings:

1. **Small substeps, few iterations.** Per-substep recompression under gravity scales
   with g·dt²; iterating harder at a large step made the fluid simmer more. 480 Hz with
   2 iterations is calmer and no more expensive than 180 Hz with 5.
2. **Under-relaxed Jacobi corrections.** Each pair correction is applied from both
   sides at once; at full strength that overshoots and neighbour-to-neighbour jitter
   grows with iteration count (0.15 m/s interior mean at rest). A relaxation factor of
   0.5 cut it to ~0.03 m/s with density within 2.6% of water.

3. **Dissipation and rest.** With no bulk energy loss, solver noise kept a few
   particles moving (max 0.35 m/s at rest) and the surface looked like it was boiling on
   the phone even though the mean was small. Real sloshing in a small bottle dies out in
   a few seconds, so a dissipation time constant (2 s) was added, plus a rest threshold
   (0.03 m/s, imperceptible) below which a particle is stopped. The harness now requires
   both mean and maximum speed at rest to reach zero, and they do within 2 s.
4. **Gravity input.** The device gravity vector is low-pass filtered (τ ≈ 0.12 s), and
   when the phone is nearly flat (in-plane magnitude < 0.25 g) the direction is frozen,
   because at that point it is mostly sensor noise and would shake the water.

Reference numbers (vessel 100×200 pt, 60% fill, Apple Silicon Mac, `-O`): ~6 ms per
60 Hz frame at 342 particles; ~570 particles for a full bottle.
