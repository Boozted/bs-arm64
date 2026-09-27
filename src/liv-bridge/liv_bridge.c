/*
 * LIV_Bridge.dll stub for the ARM64 player.
 *
 * Beat Saber ships the LIV SDK (mixed reality capture) with an x64-only native bridge.
 * The ARM64 player can't load it, so every call from LIV.dll threw DllNotFoundException:
 * about one per frame, each one logged by BSIPA. This stub exports the same functions and
 * reports "no LIV capture": LivCaptureIsActive() is false, everything else returns 0/NULL.
 *
 * All exports return 0 in x0, which is a valid result for every signature LIV.dll uses
 * (int, bool, ulong, IntPtr or void; unused arguments are ignored on AArch64).
 */
#include <stdint.h>

#define STUB(name) __declspec(dllexport) uint64_t name(void) { return 0; }

STUB(AcquireCompositorFrame)
STUB(AddObjectToChannel)
STUB(AddObjectToCompositorChannel)
STUB(AddObjectToFrame)
STUB(AddStringToChannel)
STUB(AddStringToFrame)
STUB(CommitFrame)
STUB(GetChannelObject)
STUB(GetCompositorChannelObject)
STUB(GetCompositorFrameObject)
STUB(GetCurrentTimeTicks)
STUB(GetFeatureBits)
STUB(GetObjectTag)
STUB(GetObjectTimeStamp)
STUB(GetRenderEventFunc)
STUB(GetViewportTexture)
STUB(LivCaptureHeight)
STUB(LivCaptureIsActive)
STUB(LivCaptureSetTextureFromUnity)
STUB(LivCaptureWidth)
STUB(NewFrame)
STUB(PublishTextures)
STUB(ReleaseCompositorFrame)
STUB(TelemetryEvent)
STUB(UnityPluginLoad)
STUB(UnityPluginUnload)
STUB(addsharedtexture)
STUB(addtexture)
STUB(clearfeature)
STUB(setfeature)
STUB(updateinputframe)
