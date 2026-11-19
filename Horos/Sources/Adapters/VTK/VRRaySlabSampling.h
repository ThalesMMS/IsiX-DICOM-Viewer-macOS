#ifndef VRRaySlabSampling_h
#define VRRaySlabSampling_h

#ifdef __cplusplus
extern "C" {
#endif

/* The distance between the samples of a ray, for a view volume `depth` deep
   between the camera's clipping planes, in the same units (the scene's, not
   millimetres).

   vtkFixedPointVolumeRayCastMapper gives no sample to a ray shorter than its
   sample distance, and the picture is empty. A slab is the view volume
   itself: at the usual distance of 1.2 a slab 1.05 deep was blank, and on an
   interactive render, where VTK samples every 2.0 whatever the view asked
   for, so was one 1.75 deep. The distance is kept to half the depth, so that
   a ray holds two steps; a view volume twice as deep as the distance, or
   more, is sampled as it was. */
static inline float HorosRaySampleDistanceForDepth(float distance, double depth)
{
    if (!(depth > 0) || !(distance > 0)) return distance;
    return (double)distance > depth / 2 ? (float)(depth / 2) : distance;
}

#ifdef __cplusplus
}
#endif

#endif
