/*
 * XrApiLayer_bs_arm64_gaze.dll: OpenXR API layer that makes SteamVR's eye-tracked foveation
 * centers available to DXVK in the same process.
 *
 * DXVK renders Beat Saber's eyes with a fragment density map (patches/dxvk/0004, 0006). It can't
 * ask OpenXR itself, so this layer enables XR_META_foveation_eye_tracked (with the XR_FB_foveation
 * and XR_FB_swapchain_update_state extensions it requires), polls
 * xrGetFoveationEyeTrackedStateMETA whenever the game calls xrLocateViews (once or twice per
 * frame, right before rendering), and exports the latest centers:
 *
 *   int bs_arm64_gaze(float centers[4], uint64_t *age_us)
 *
 * centers = left x, y, right x, y in the eye's NDC as OpenXR reports them. Returns 1 once the
 * runtime has reported valid centers at least once; age_us is the time since the last valid ones.
 *
 * The layer is implicit and only loads when BS_ARM64_FDM is set (manifest enable_environment).
 * If the runtime lacks the extensions, the instance is created without them and the layer does
 * nothing. BS_ARM64_GAZE_LOG=<file> logs the state every 2 s to that file (Unity swallows stderr).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>

#define LAYER_NAME "XR_APILAYER_bs_arm64_gaze"

static PFN_xrGetInstanceProcAddr next_gipa;
static PFN_xrLocateViews next_locate_views;
static PFN_xrCreateSession next_create_session;
static PFN_xrDestroySession next_destroy_session;
static PFN_xrGetFoveationEyeTrackedStateMETA next_get_state;
static PFN_xrCreateReferenceSpace next_create_ref_space;
static XrSpace view_space = XR_NULL_HANDLE;

static int enabled; /* extensions were accepted by the runtime */
static FILE *log_file;
static XrSession session = XR_NULL_HANDLE;

static SRWLOCK lock = SRWLOCK_INIT;
static float centers[4];
static LARGE_INTEGER last_valid; /* 0: never valid */
static LARGE_INTEGER freq;

/* log counters */
static LARGE_INTEGER last_log;
static unsigned polls, valid_polls, errors;
static XrResult last_error;
static float range[4][2]; /* min/max of each center coordinate since the last log line */

static void trace(const char *fmt, ...)
{
    va_list ap;
    if (!log_file) return;
    va_start(ap, fmt);
    vfprintf(log_file, fmt, ap);
    fputc('\n', log_file);
    fflush(log_file);
    va_end(ap);
}

__declspec(dllexport) int bs_arm64_gaze(float out[4], uint64_t *age_us)
{
    LARGE_INTEGER now;
    int ok;

    QueryPerformanceCounter(&now);
    AcquireSRWLockShared(&lock);
    ok = last_valid.QuadPart != 0;
    if (ok)
    {
        memcpy(out, centers, sizeof(centers));
        if (age_us) *age_us = (uint64_t)(now.QuadPart - last_valid.QuadPart) * 1000000u / (uint64_t)freq.QuadPart;
    }
    ReleaseSRWLockShared(&lock);
    return ok;
}

static void poll_gaze(void)
{
    XrFoveationEyeTrackedStateMETA state = { XR_TYPE_FOVEATION_EYE_TRACKED_STATE_META };
    LARGE_INTEGER now;
    XrResult res;

    if (!enabled || session == XR_NULL_HANDLE) return;

    res = next_get_state(session, &state);
    QueryPerformanceCounter(&now);
    polls++;

    if (res == XR_SUCCESS && (state.flags & XR_FOVEATION_EYE_TRACKED_STATE_VALID_BIT_META))
    {
        AcquireSRWLockExclusive(&lock);
        centers[0] = state.foveationCenter[0].x;
        centers[1] = state.foveationCenter[0].y;
        centers[2] = state.foveationCenter[1].x;
        centers[3] = state.foveationCenter[1].y;
        last_valid = now;
        ReleaseSRWLockExclusive(&lock);
        for (int i = 0; i < 4; i++)
        {
            if (!valid_polls || centers[i] < range[i][0]) range[i][0] = centers[i];
            if (!valid_polls || centers[i] > range[i][1]) range[i][1] = centers[i];
        }
        valid_polls++;
    }
    else if (res != XR_SUCCESS)
    {
        errors++;
        last_error = res;
    }

    if (log_file && now.QuadPart - last_log.QuadPart > 2 * freq.QuadPart)
    {
        trace("%u polls, %u valid, %u errors (last %d); L x %.2f..%.2f y %.2f..%.2f, R x %.2f..%.2f y %.2f..%.2f",
              polls, valid_polls, errors, last_error, range[0][0], range[0][1], range[1][0], range[1][1],
              range[2][0], range[2][1], range[3][0], range[3][1]);
        last_log = now;
        polls = valid_polls = errors = 0;
    }
}

static XrResult XRAPI_CALL layer_xrLocateViews(XrSession s, const XrViewLocateInfo *info, XrViewState *view_state,
                                              uint32_t capacity, uint32_t *count, XrView *views)
{
    XrResult res = next_locate_views(s, info, view_state, capacity, count, views);
    if (res == XR_SUCCESS && views) poll_gaze();
    if (res == XR_SUCCESS && views && *count >= 2 && log_file)
    {
        static int logged;
        if (logged++ % 1200 == 0)
        {
            trace("fov L %.3f %.3f %.3f %.3f  R %.3f %.3f %.3f %.3f (left right up down, rad)",
                  views[0].fov.angleLeft, views[0].fov.angleRight, views[0].fov.angleUp, views[0].fov.angleDown,
                  views[1].fov.angleLeft, views[1].fov.angleRight, views[1].fov.angleUp, views[1].fov.angleDown);

            /* the views relative to the head (VIEW space): yaw/pitch/roll in degrees */
            if (view_space != XR_NULL_HANDLE)
            {
                XrViewLocateInfo head_info = *info;
                XrViewState head_state = { XR_TYPE_VIEW_STATE };
                XrView head_views[2] = { { XR_TYPE_VIEW }, { XR_TYPE_VIEW } };
                uint32_t n = 0;
                head_info.space = view_space;
                if (next_locate_views(s, &head_info, &head_state, 2, &n, head_views) == XR_SUCCESS)
                {
                    for (uint32_t i = 0; i < n; i++)
                    {
                        XrQuaternionf q = head_views[i].pose.orientation;
                        double yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.x * q.x + q.y * q.y));
                        double pitch = asin(fmax(-1, fmin(1, 2 * (q.w * q.x - q.y * q.z))));
                        double roll = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.x * q.x + q.z * q.z));
                        trace("view %u vs head: yaw %.2f pitch %.2f roll %.2f deg, pos %.4f %.4f %.4f", i,
                              yaw * 57.2958, pitch * 57.2958, roll * 57.2958, head_views[i].pose.position.x,
                              head_views[i].pose.position.y, head_views[i].pose.position.z);
                    }
                }
            }
        }
    }
    return res;
}

static XrResult XRAPI_CALL layer_xrCreateSession(XrInstance instance, const XrSessionCreateInfo *info, XrSession *out)
{
    XrResult res = next_create_session(instance, info, out);
    if (res != XR_SUCCESS || !enabled) return res;

    PFN_xrGetSystemProperties get_props;
    XrSystemFoveationEyeTrackedPropertiesMETA fove = { XR_TYPE_SYSTEM_FOVEATION_EYE_TRACKED_PROPERTIES_META };
    XrSystemProperties props = { XR_TYPE_SYSTEM_PROPERTIES, &fove };

    if (next_gipa(instance, "xrGetSystemProperties", (PFN_xrVoidFunction *)&get_props) == XR_SUCCESS &&
        get_props(instance, info->systemId, &props) == XR_SUCCESS && !fove.supportsFoveationEyeTracked)
    {
        trace("the runtime doesn't support eye-tracked foveation");
        return res;
    }
    trace("eye-tracked foveation supported, session %p", (void *)*out);
    session = *out;

    if (log_file && next_create_ref_space)
    {
        XrReferenceSpaceCreateInfo space_info = { XR_TYPE_REFERENCE_SPACE_CREATE_INFO };
        space_info.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        space_info.poseInReferenceSpace.orientation.w = 1.0f;
        view_space = XR_NULL_HANDLE;
        next_create_ref_space(*out, &space_info, &view_space);
    }
    return res;
}

static XrResult XRAPI_CALL layer_xrDestroySession(XrSession s)
{
    if (s == session)
    {
        session = XR_NULL_HANDLE;
        AcquireSRWLockExclusive(&lock);
        last_valid.QuadPart = 0;
        ReleaseSRWLockExclusive(&lock);
    }
    return next_destroy_session(s);
}

static XrResult XRAPI_CALL layer_xrGetInstanceProcAddr(XrInstance instance, const char *name, PFN_xrVoidFunction *function)
{
#define HOOK(fn) if (!strcmp(name, #fn)) { *function = (PFN_xrVoidFunction)layer_##fn; return XR_SUCCESS; }
    HOOK(xrGetInstanceProcAddr)
    if (enabled)
    {
        HOOK(xrLocateViews)
        HOOK(xrCreateSession)
        HOOK(xrDestroySession)
    }
#undef HOOK
    return next_gipa(instance, name, function);
}

static const char *wanted_extensions[] = {
    XR_FB_SWAPCHAIN_UPDATE_STATE_EXTENSION_NAME,
    XR_FB_FOVEATION_EXTENSION_NAME,
    XR_META_FOVEATION_EYE_TRACKED_EXTENSION_NAME,
};

static XrResult XRAPI_CALL layer_xrCreateApiLayerInstance(const XrInstanceCreateInfo *info,
                                                         const XrApiLayerCreateInfo *layer_info, XrInstance *instance)
{
    XrApiLayerCreateInfo next_layer_info = *layer_info;
    XrInstanceCreateInfo with_ext = *info;
    const char **names;
    uint32_t i, j, n = info->enabledExtensionCount;
    XrResult res;

    QueryPerformanceFrequency(&freq);
    if (!log_file && getenv("BS_ARM64_GAZE_LOG")) log_file = fopen(getenv("BS_ARM64_GAZE_LOG"), "a");

    next_gipa = layer_info->nextInfo->nextGetInstanceProcAddr;
    next_layer_info.nextInfo = layer_info->nextInfo->next;

    names = malloc((n + ARRAYSIZE(wanted_extensions)) * sizeof(*names));
    memcpy(names, info->enabledExtensionNames, n * sizeof(*names));
    for (i = 0; i < ARRAYSIZE(wanted_extensions); i++)
    {
        for (j = 0; j < info->enabledExtensionCount; j++)
            if (!strcmp(info->enabledExtensionNames[j], wanted_extensions[i])) break;
        if (j == info->enabledExtensionCount) names[n++] = wanted_extensions[i];
    }
    with_ext.enabledExtensionCount = n;
    with_ext.enabledExtensionNames = names;

    res = layer_info->nextInfo->nextCreateApiLayerInstance(&with_ext, &next_layer_info, instance);
    free(names);
    if (res == XR_SUCCESS)
    {
        enabled = 1;
        next_gipa(*instance, "xrLocateViews", (PFN_xrVoidFunction *)&next_locate_views);
        next_gipa(*instance, "xrCreateSession", (PFN_xrVoidFunction *)&next_create_session);
        next_gipa(*instance, "xrDestroySession", (PFN_xrVoidFunction *)&next_destroy_session);
        next_gipa(*instance, "xrGetFoveationEyeTrackedStateMETA", (PFN_xrVoidFunction *)&next_get_state);
        next_gipa(*instance, "xrCreateReferenceSpace", (PFN_xrVoidFunction *)&next_create_ref_space);
        enabled = next_locate_views && next_create_session && next_destroy_session && next_get_state;
        trace("instance created with eye-tracked foveation extensions%s", enabled ? "" : ", but functions are missing");
        return res;
    }

    trace("runtime refused the foveation extensions (%d), continuing without eye tracking", res);
    return layer_info->nextInfo->nextCreateApiLayerInstance(info, &next_layer_info, instance);
}

__declspec(dllexport) XrResult XRAPI_CALL xrNegotiateLoaderApiLayerInterface(const XrNegotiateLoaderInfo *loader_info,
                                                                             const char *layer_name,
                                                                             XrNegotiateApiLayerRequest *request)
{
    if (!loader_info || !request || strcmp(layer_name, LAYER_NAME) ||
        loader_info->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
        request->structType != XR_LOADER_INTERFACE_STRUCT_API_LAYER_REQUEST ||
        loader_info->minInterfaceVersion > XR_CURRENT_LOADER_API_LAYER_VERSION ||
        loader_info->maxInterfaceVersion < XR_CURRENT_LOADER_API_LAYER_VERSION)
        return XR_ERROR_INITIALIZATION_FAILED;

    request->layerInterfaceVersion = XR_CURRENT_LOADER_API_LAYER_VERSION;
    request->layerApiVersion = XR_CURRENT_API_VERSION;
    request->getInstanceProcAddr = layer_xrGetInstanceProcAddr;
    request->createApiLayerInstance = layer_xrCreateApiLayerInstance;
    return XR_SUCCESS;
}
