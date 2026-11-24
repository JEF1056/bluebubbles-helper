#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

#define BB_RING_PATH "/private/var/tmp/AVConference/bb-camera.ring"
#define BB_DOWNLINK_RING_PATH "/private/var/tmp/AVConference/bb-downlink.ring"
#define BB_CAMERA_ACTIVE_PATH "/private/var/tmp/AVConference/bb-camera.active"
#define BB_RING_MAGIC 0x42424352u // 'BBCR'
#define BB_RING_VERSION 1u
#define BB_RING_MAX_DIM 1920u
#define BB_RING_MAX_PIXELS (1920u * 1080u)
#define BB_DOWNLINK_RING_SLOTS 3u
#define BB_DOWNLINK_SLOT_BYTES (1920u * 1080u * 3u / 2u)
#define BB_RING_STALE_NS 500000000ULL // 500 ms
#define BB_RING_TEARDOWN_STALE_NS 3000000000ULL // 3 s
#define BB_RING_LSTAT_INTERVAL_NS 200000000ULL // 200 ms

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
    _Atomic uint64_t seq;
    uint64_t ts_ns;
    uint32_t slots;
    uint32_t slot_bytes;
    uint32_t orientation; // VideoAttributes orientation (0=Portrait, 1=PortraitUpsideDown, 2=LandscapeLeft, 3=LandscapeRight)
    uint32_t flags;       // bit 0: orientation is valid
    uint8_t reserved[8];
} BBCameraRingHeader;

_Static_assert(sizeof(BBCameraRingHeader) == 64, "BBCameraRingHeader must be 64 bytes");

static uint64_t bb_now_ns(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info(&tb);
    });
    uint64_t t = mach_continuous_time();
    return (uint64_t)(((__uint128_t)t * tb.numer) / tb.denom);
}

typedef struct {
    int fd;
    void *map;
    size_t map_size;
    ino_t ino;
    uint64_t last_open_attempt_ns;
    uint64_t last_lstat_ns;

    VTPixelTransferSessionRef transfer_session;
    VTPixelRotationSessionRef rotation_session API_AVAILABLE(macos(13.0));
    CVPixelBufferPoolRef src_pool;
    uint32_t src_w;
    uint32_t src_h;

    CVPixelBufferPoolRef dst_pool;
    uint32_t dst_w;
    uint32_t dst_h;
    OSType dst_fmt;
} BBCameraRingReader;

static os_unfair_lock g_reader_lock = OS_UNFAIR_LOCK_INIT;
static BBCameraRingReader g_reader = {.fd = -1};
static const char *g_ringPath = BB_RING_PATH;
static const char *g_activeFlagPath = BB_CAMERA_ACTIVE_PATH;
static const char *g_downlinkRingPath = BB_DOWNLINK_RING_PATH;

void BBCameraHookSetRingPathForTesting(const char *path) {
    g_ringPath = path ? path : BB_RING_PATH;
}

void BBCameraHookSetActiveFlagPathForTesting(const char *path) {
    g_activeFlagPath = path ? path : BB_CAMERA_ACTIVE_PATH;
}

void BBCameraHookSetDownlinkRingPathForTesting(const char *path) {
    g_downlinkRingPath = path ? path : BB_DOWNLINK_RING_PATH;
}

static void bb_reader_unmap(BBCameraRingReader *r) {
    if (r->map && r->map != MAP_FAILED) {
        munmap(r->map, r->map_size);
    }
    r->map = NULL;
    r->map_size = 0;
    if (r->fd >= 0) {
        close(r->fd);
        r->fd = -1;
    }
    r->ino = 0;
    r->last_lstat_ns = 0;
}

static void bb_release_gpu_resources(BBCameraRingReader *r) {
    if (r->src_pool) {
        CFRelease(r->src_pool);
        r->src_pool = NULL;
    }
    r->src_w = 0;
    r->src_h = 0;
    if (r->dst_pool) {
        CFRelease(r->dst_pool);
        r->dst_pool = NULL;
    }
    r->dst_w = 0;
    r->dst_h = 0;
    r->dst_fmt = 0;
    if (r->transfer_session) {
        VTPixelTransferSessionInvalidate(r->transfer_session);
        CFRelease(r->transfer_session);
        r->transfer_session = NULL;
    }
    if (@available(macOS 13.0, *)) {
        if (r->rotation_session) {
            VTPixelRotationSessionInvalidate(r->rotation_session);
            CFRelease(r->rotation_session);
            r->rotation_session = NULL;
        }
    }
}

static void bb_close_ring(BBCameraRingReader *r) {
    bb_reader_unmap(r);
    bb_release_gpu_resources(r);
}

static CVPixelBufferPoolRef bb_create_pool(uint32_t w, uint32_t h, OSType fmt) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess) {
        return NULL;
    }
    return pool;
}

static bool bb_ensure_mapped(BBCameraRingReader *r, const char *path, uint64_t now_ns) {
    struct stat st;
    if (r->fd >= 0) {
        if (r->last_lstat_ns == 0 || (now_ns > r->last_lstat_ns && (now_ns - r->last_lstat_ns) >= BB_RING_LSTAT_INTERVAL_NS)) {
            r->last_lstat_ns = now_ns;
            if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode) || (st.st_mode & 022) != 0 ||
                st.st_ino != r->ino || (size_t)st.st_size != r->map_size) {
                bb_close_ring(r);
            } else {
                return true;
            }
        } else {
            return true;
        }
    }

    if (now_ns - r->last_open_attempt_ns < 200000000ULL && r->last_open_attempt_ns != 0) {
        return false;
    }
    r->last_open_attempt_ns = now_ns;

    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return false;

    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (st.st_mode & 022) != 0 ||
        st.st_size < (off_t)sizeof(BBCameraRingHeader)) {
        close(fd);
        return false;
    }

    size_t sz = (size_t)st.st_size;
    void *m = mmap(NULL, sz, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) {
        close(fd);
        return false;
    }

    r->fd = fd;
    r->map = m;
    r->map_size = sz;
    r->ino = st.st_ino;
    r->last_lstat_ns = now_ns;
    return true;
}

static void bb_notify_uplink_orientation(uint32_t w, uint32_t h);
static bool bb_is_avconferenced(void);

CMSampleBufferRef BBCameraHookCreateSampleBufferFromRing(
    uint32_t dstW,
    uint32_t dstH,
    OSType dstFmt,
    const CMSampleTimingInfo *timing,
    const char *ringPath)
{
    if (!timing || !ringPath) return NULL;

    uint64_t now_ns = bb_now_ns();

    os_unfair_lock_lock(&g_reader_lock);

    if (!bb_ensure_mapped(&g_reader, ringPath, now_ns)) {
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    const BBCameraRingHeader *hdr = (const BBCameraRingHeader *)g_reader.map;
    uint64_t s1 = atomic_load_explicit(&((BBCameraRingHeader *)g_reader.map)->seq, memory_order_acquire);
    if (s1 == 0 || (s1 & 1ULL) != 0) {
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    uint32_t magic = hdr->magic;
    uint32_t version = hdr->version;
    uint32_t w = hdr->width;
    uint32_t h = hdr->height;
    uint32_t stride = hdr->stride;
    uint32_t fmt = hdr->format;
    uint32_t slots = hdr->slots;
    uint32_t slot_bytes = hdr->slot_bytes;
    uint64_t ts_ns = hdr->ts_ns;

    if (magic != BB_RING_MAGIC || version != BB_RING_VERSION ||
        w == 0 || w > BB_RING_MAX_DIM || h == 0 || h > BB_RING_MAX_DIM ||
        (uint64_t)w * (uint64_t)h > BB_RING_MAX_PIXELS ||
        (w & 1u) != 0 || (h & 1u) != 0 ||
        stride < w || fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        slots == 0 || slots > 16 ||
        (size_t)slot_bytes < (size_t)stride * (size_t)h * 3 / 2 ||
        (size_t)slots * (size_t)slot_bytes > g_reader.map_size - sizeof(BBCameraRingHeader)) {
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    if (ts_ns == 0 || (now_ns > ts_ns && (now_ns - ts_ns) >= BB_RING_STALE_NS)) {
        if (ts_ns == 0 || (now_ns > ts_ns && (now_ns - ts_ns) >= BB_RING_TEARDOWN_STALE_NS)) {
            bb_release_gpu_resources(&g_reader);
        }
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    if (dstW == 0 || dstH == 0) {
        dstW = w;
        dstH = h;
    }
    if (h > w) {
        if (bb_is_avconferenced()) {
            // VideoTransmitter only enters its portrait conversion path for exact 1080x1920 input.
            dstW = 1080;
            dstH = 1920;
        } else if (dstW > dstH) {
            uint32_t tmp = dstW;
            dstW = dstH;
            dstH = tmp;
        }
    }
    BOOL needsCCW90 = NO;
    if (dstFmt == 0) {
        dstFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }

    if (!g_reader.src_pool || g_reader.src_w != w || g_reader.src_h != h) {
        if (g_reader.src_pool) CFRelease(g_reader.src_pool);
        g_reader.src_pool = bb_create_pool(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        g_reader.src_w = w;
        g_reader.src_h = h;
    }
    if (!g_reader.dst_pool || g_reader.dst_w != dstW || g_reader.dst_h != dstH || g_reader.dst_fmt != dstFmt) {
        if (g_reader.dst_pool) CFRelease(g_reader.dst_pool);
        g_reader.dst_pool = bb_create_pool(dstW, dstH, dstFmt);
        g_reader.dst_w = dstW;
        g_reader.dst_h = dstH;
        g_reader.dst_fmt = dstFmt;
    }
    if (needsCCW90) {
        if (@available(macOS 13.0, *)) {
            if (!g_reader.rotation_session) {
                if (VTPixelRotationSessionCreate(kCFAllocatorDefault, &g_reader.rotation_session) == noErr && g_reader.rotation_session) {
                    VTSessionSetProperty(g_reader.rotation_session, kVTPixelRotationPropertyKey_Rotation, kVTRotation_CCW90);
                }
            }
        }
    }
    if (!g_reader.transfer_session) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &g_reader.transfer_session) == noErr && g_reader.transfer_session) {
            VTSessionSetProperty(g_reader.transfer_session, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Letterbox);
        }
    }

    BOOL hasRotSession = NO;
    if (@available(macOS 13.0, *)) {
        hasRotSession = (g_reader.rotation_session != NULL);
    }
    if (!g_reader.src_pool || !g_reader.dst_pool || (needsCCW90 ? !hasRotSession : !g_reader.transfer_session)) {
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    CVPixelBufferRef srcBuf = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_reader.src_pool, &srcBuf) != kCVReturnSuccess || !srcBuf) {
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    uint32_t slotIdx = (uint32_t)(((s1 / 2ULL) - 1ULL) % slots);
    const uint8_t *slotPtr = (const uint8_t *)g_reader.map + sizeof(BBCameraRingHeader) + (size_t)slotIdx * (size_t)slot_bytes;

    if (CVPixelBufferLockBaseAddress(srcBuf, 0) != kCVReturnSuccess) {
        CFRelease(srcBuf);
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }
    uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(srcBuf, 0);
    size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(srcBuf, 0);
    uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(srcBuf, 1);
    size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(srcBuf, 1);
    if (!dstY || !dstUV || dstYStride < w || dstUVStride < w) {
        CVPixelBufferUnlockBaseAddress(srcBuf, 0);
        CFRelease(srcBuf);
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }
    for (uint32_t row = 0; row < h; row++) {
        memcpy(dstY + (size_t)row * dstYStride, slotPtr + (size_t)row * stride, w);
    }

    const uint8_t *srcUV = slotPtr + (size_t)stride * (size_t)h;
    uint32_t uvH = h / 2;
    for (uint32_t row = 0; row < uvH; row++) {
        memcpy(dstUV + (size_t)row * dstUVStride, srcUV + (size_t)row * stride, w);
    }
    CVPixelBufferUnlockBaseAddress(srcBuf, 0);

    atomic_thread_fence(memory_order_acquire);
    uint64_t s2 = atomic_load_explicit(&((BBCameraRingHeader *)g_reader.map)->seq, memory_order_acquire);
    if (s1 != s2) {
        CFRelease(srcBuf);
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }
    if (bb_is_avconferenced()) {
        bb_notify_uplink_orientation(w, h);
    }

    // Tag source 420v buffer with Rec.709 color-space attachments so VTPixelTransfer + formatDesc preserve them
    CVBufferSetAttachment(srcBuf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(srcBuf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(srcBuf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);

    CVPixelBufferRef dstBuf = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_reader.dst_pool, &dstBuf) != kCVReturnSuccess || !dstBuf) {
        CFRelease(srcBuf);
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    VTPixelTransferSessionRef xferSession = NULL;
    VTPixelRotationSessionRef rotSession API_AVAILABLE(macos(13.0)) = NULL;
    if (needsCCW90) {
        if (@available(macOS 13.0, *)) {
            rotSession = g_reader.rotation_session;
            if (rotSession) CFRetain(rotSession);
        }
    } else {
        xferSession = g_reader.transfer_session;
        if (xferSession) CFRetain(xferSession);
    }
    os_unfair_lock_unlock(&g_reader_lock);

    OSStatus xferStatus = -1;
    if (needsCCW90) {
        if (@available(macOS 13.0, *)) {
            if (rotSession) {
                xferStatus = VTPixelRotationSessionRotateImage(rotSession, srcBuf, dstBuf);
                CFRelease(rotSession);
            }
        }
    } else {
        if (xferSession) {
            xferStatus = VTPixelTransferSessionTransferImage(xferSession, srcBuf, dstBuf);
            CFRelease(xferSession);
        }
    }
    CFRelease(srcBuf);

    if (xferStatus != noErr) {
        CFRelease(dstBuf);
        return NULL;
    }

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, dstBuf, &fmtDesc) != noErr || !fmtDesc) {
        CFRelease(dstBuf);
        return NULL;
    }

    CMSampleBufferRef outSample = NULL;
    OSStatus sbStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, dstBuf, fmtDesc, timing, &outSample);
    CFRelease(fmtDesc);
    CFRelease(dstBuf);

    if (sbStatus != noErr) {
        if (outSample) CFRelease(outSample);
        return NULL;
    }
    return outSample;
}

CMSampleBufferRef BBCameraHookCreateSwappedSampleBuffer(CMSampleBufferRef origSampleBuffer, const char *ringPath) {
    if (!origSampleBuffer || !ringPath) return NULL;

    CVImageBufferRef origImg = CMSampleBufferGetImageBuffer(origSampleBuffer);
    if (!origImg) return NULL;

    uint32_t dstW = (uint32_t)CVPixelBufferGetWidth(origImg);
    uint32_t dstH = (uint32_t)CVPixelBufferGetHeight(origImg);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(origImg);
    if (dstW == 0 || dstH == 0) return NULL;

    CMSampleTimingInfo timing = kCMTimingInfoInvalid;
    if (CMSampleBufferGetSampleTimingInfo(origSampleBuffer, 0, &timing) != noErr) {
        return NULL;
    }

    return BBCameraHookCreateSampleBufferFromRing(dstW, dstH, dstFmt, &timing, ringPath);
}

@interface BBProxyDelegate : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate> {
    os_unfair_lock _pumpLock;
    dispatch_source_t _pumpTimer;
    _Atomic uint64_t _lastRealFrameNs;
    CMTime _lastSyntheticPTS;
}
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@property (nonatomic, weak) id output;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
- (instancetype)initWithTarget:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)target
                        output:(id)output
                         queue:(dispatch_queue_t)queue;
- (void)startPumpIfNeeded;
- (void)stopPump;
@end

@implementation BBProxyDelegate

- (instancetype)initWithTarget:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)target
                        output:(id)output
                         queue:(dispatch_queue_t)queue {
    _target = target;
    _output = output;
    _callbackQueue = queue;
    _pumpLock = OS_UNFAIR_LOCK_INIT;
    _pumpTimer = nil;
    atomic_store_explicit(&_lastRealFrameNs, 0, memory_order_relaxed);
    _lastSyntheticPTS = kCMTimeInvalid;
    return self;
}

- (void)dealloc {
    [self stopPump];
}

- (void)startPumpIfNeeded {
    if (!_callbackQueue || !_target || !_output) return;

    os_unfair_lock_lock(&_pumpLock);
    if (!_pumpTimer) {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _callbackQueue);
        if (timer) {
            uint64_t intervalNs = NSEC_PER_SEC / 30;
            dispatch_source_set_timer(timer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                                      intervalNs,
                                      NSEC_PER_MSEC * 5);
            __weak BBProxyDelegate *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf pumpTick];
            });
            _pumpTimer = timer;
            dispatch_resume(timer);
        }
    }
    os_unfair_lock_unlock(&_pumpLock);
}

- (void)stopPump {
    os_unfair_lock_lock(&_pumpLock);
    dispatch_source_t timer = _pumpTimer;
    _pumpTimer = nil;
    os_unfair_lock_unlock(&_pumpLock);
    if (timer) {
        dispatch_source_cancel(timer);
    }
}

static uint32_t bb_u32(id v) {
    if ([v isKindOfClass:[NSArray class]]) {
        v = [(NSArray *)v firstObject];
    }
    return [v isKindOfClass:[NSNumber class]] ? [v unsignedIntValue] : 0;
}

- (void)pumpTick {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = _target;
    id output = _output;
    if (!target || !output) {
        [self stopPump];
        return;
    }

    uint64_t nowNs = bb_now_ns();
    uint64_t lastReal = atomic_load_explicit(&_lastRealFrameNs, memory_order_relaxed);
    if (lastReal != 0 && nowNs > lastReal && (nowNs - lastReal) < 250000000ULL) {
        return;
    }

    SEL sessionSel = @selector(session);
    if (![output respondsToSelector:sessionSel]) return;
    id session = ((id (*)(id, SEL))objc_msgSend)(output, sessionSel);
    if (!session || ![session respondsToSelector:@selector(isRunning)]) return;
    BOOL isRunning = ((BOOL (*)(id, SEL))objc_msgSend)(session, @selector(isRunning));
    if (!isRunning) return;

    if (![output respondsToSelector:@selector(connectionWithMediaType:)]) return;
    AVCaptureConnection *conn = [output connectionWithMediaType:AVMediaTypeVideo];
    if (!conn || !conn.isEnabled || !conn.isActive) return;

    uint32_t dstW = 0;
    uint32_t dstH = 0;
    OSType dstFmt = 0;
    if ([output respondsToSelector:@selector(videoSettings)]) {
        NSDictionary *settings = [output videoSettings];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            dstW = bb_u32(settings[(id)kCVPixelBufferWidthKey]);
            dstH = bb_u32(settings[(id)kCVPixelBufferHeightKey]);
            dstFmt = (OSType)bb_u32(settings[(id)kCVPixelBufferPixelFormatTypeKey]);
        }
    }

    AVCaptureInputPort *port = conn.inputPorts.firstObject;
    if (dstW == 0 || dstH == 0) {
        CMFormatDescriptionRef portFmt = (port && [port respondsToSelector:@selector(formatDescription)]) ? port.formatDescription : NULL;
        if (portFmt) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(portFmt);
            if (dims.width > 0 && dims.height > 0) {
                dstW = (uint32_t)dims.width;
                dstH = (uint32_t)dims.height;
            }
            if (dstFmt == 0) {
                dstFmt = CMFormatDescriptionGetMediaSubType(portFmt);
            }
        }
    }

    CMClockRef clock = (port && [port respondsToSelector:@selector(clock)]) ? port.clock : NULL;
    if (!clock) {
        clock = CMClockGetHostTimeClock();
    }
    CMTime pts = CMClockGetTime(clock);
    os_unfair_lock_lock(&_pumpLock);
    if (CMTIME_IS_VALID(_lastSyntheticPTS) && CMTimeCompare(pts, _lastSyntheticPTS) <= 0) {
        int32_t ts = pts.timescale > 0 ? pts.timescale : 1000000000;
        pts = CMTimeAdd(_lastSyntheticPTS, CMTimeMake(1, ts));
    }
    _lastSyntheticPTS = pts;
    os_unfair_lock_unlock(&_pumpLock);

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef synthetic = NULL;
    @try {
        synthetic = BBCameraHookCreateSampleBufferFromRing(dstW, dstH, dstFmt, &timing, g_ringPath);
    } @catch (NSException *ex) {
        synthetic = NULL;
    }

    if (synthetic) {
        static atomic_flag loggedFirstSynthetic = ATOMIC_FLAG_INIT;
        if (!atomic_flag_test_and_set_explicit(&loggedFirstSynthetic, memory_order_relaxed)) {
            os_log(OS_LOG_DEFAULT, "BlueBubblesCameraHook: pumping first synthetic clamshell frame (%ux%u fmt=0x%x)",
                   dstW, dstH, (unsigned int)dstFmt);
        }
        [target captureOutput:output didOutputSampleBuffer:synthetic fromConnection:conn];
        CFRelease(synthetic);
    }
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return _target;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) {
        return [_target respondsToSelector:aSelector];
    }
    return [_target respondsToSelector:aSelector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    id t = _target;
    return t ? [t methodSignatureForSelector:sel] : [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id t = _target;
    if (t) {
        [invocation invokeWithTarget:t];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    atomic_store_explicit(&_lastRealFrameNs, bb_now_ns(), memory_order_relaxed);
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = _target;
    if (!target) return;

    CMSampleBufferRef swapped = NULL;
    @try {
        swapped = BBCameraHookCreateSwappedSampleBuffer(sampleBuffer, g_ringPath);
    } @catch (NSException *ex) {
        swapped = NULL;
    }

    if (swapped) {
        static atomic_flag loggedFirstSwap = ATOMIC_FLAG_INIT;
        if (!atomic_flag_test_and_set_explicit(&loggedFirstSwap, memory_order_relaxed)) {
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: returning first swapped frame");
        }
        [target captureOutput:output didOutputSampleBuffer:swapped fromConnection:connection];
        CFRelease(swapped);
    } else {
        [target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

static const void *kBBProxyAssocKey = &kBBProxyAssocKey;
static IMP g_origSetSampleBufferDelegate = NULL;
static IMP g_origSetSampleBufferDelegateTundra = NULL;
static NSHashTable<id> *g_activeOutputs = nil;

static void bb_handle_setSampleBufferDelegate(
    id self,
    SEL _cmd,
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
    dispatch_queue_t queue,
    IMP origIMP)
{
    static atomic_flag loggedFirstDelegate = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set_explicit(&loggedFirstDelegate, memory_order_relaxed)) {
        os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: intercepted setSampleBufferDelegate:queue: on %{public}@ (delegate=%{public}@)",
                    NSStringFromClass(object_getClass(self)),
                    delegate ? NSStringFromClass(object_getClass(delegate)) : @"nil");
    }

    BBProxyDelegate *oldProxy = objc_getAssociatedObject(self, kBBProxyAssocKey);
    if (oldProxy && oldProxy != delegate) {
        [oldProxy stopPump];
    }

    id<AVCaptureVideoDataOutputSampleBufferDelegate> forwardDelegate = delegate;
    BBProxyDelegate *newProxy = nil;
    if (delegate && object_getClass(delegate) != [BBProxyDelegate class]) {
        newProxy = [[BBProxyDelegate alloc] initWithTarget:delegate output:self queue:queue];
        forwardDelegate = newProxy;
    }

    ((void (*)(id, SEL, id, dispatch_queue_t))origIMP)(self, _cmd, forwardDelegate, queue);

    if (newProxy) {
        objc_setAssociatedObject(self, kBBProxyAssocKey, newProxy, OBJC_ASSOCIATION_RETAIN);
        @synchronized ([BBProxyDelegate class]) {
            if (!g_activeOutputs) {
                g_activeOutputs = [NSHashTable weakObjectsHashTable];
            }
            [g_activeOutputs addObject:self];
        }
        [newProxy startPumpIfNeeded];
    } else if (!delegate) {
        BOOL hadProxy = (oldProxy != nil);
        objc_setAssociatedObject(self, kBBProxyAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
        if (hadProxy) {
            BOOL shouldClose = NO;
            @synchronized ([BBProxyDelegate class]) {
                [g_activeOutputs removeObject:self];
                shouldClose = ([g_activeOutputs allObjects].count == 0);
            }
            if (shouldClose) {
                os_unfair_lock_lock(&g_reader_lock);
                bb_close_ring(&g_reader);
                os_unfair_lock_unlock(&g_reader_lock);
            }
        }
    }
}

static void bb_swizzled_setSampleBufferDelegate(
    id self,
    SEL _cmd,
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
    dispatch_queue_t queue)
{
    bb_handle_setSampleBufferDelegate(self, _cmd, delegate, queue, g_origSetSampleBufferDelegate);
}

static void bb_swizzled_setSampleBufferDelegate_tundra(
    id self,
    SEL _cmd,
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
    dispatch_queue_t queue)
{
    bb_handle_setSampleBufferDelegate(self, _cmd, delegate, queue, g_origSetSampleBufferDelegateTundra);
}

static BOOL bb_should_unsuspend_camera(void) {
    if (g_activeFlagPath && access(g_activeFlagPath, F_OK) == 0) {
        return YES;
    }
    @synchronized ([BBProxyDelegate class]) {
        if (g_activeOutputs && [g_activeOutputs allObjects].count > 0) {
            return YES;
        }
    }
    return NO;
}

static IMP g_origIsSuspendedBase = NULL;
static IMP g_origIsSuspendedTundra = NULL;
static IMP g_origIsSuspendedDAL = NULL;

static BOOL bb_handle_isSuspended(id self, SEL _cmd, IMP origIMP) {
    if (bb_should_unsuspend_camera()) {
        return NO;
    }
    if (origIMP) {
        return ((BOOL (*)(id, SEL))origIMP)(self, _cmd);
    }
    return NO;
}

static BOOL bb_swizzled_isSuspended_base(id self, SEL _cmd) {
    return bb_handle_isSuspended(self, _cmd, g_origIsSuspendedBase);
}

static BOOL bb_swizzled_isSuspended_tundra(id self, SEL _cmd) {
    return bb_handle_isSuspended(self, _cmd, g_origIsSuspendedTundra);
}

static BOOL bb_swizzled_isSuspended_dal(id self, SEL _cmd) {
    return bb_handle_isSuspended(self, _cmd, g_origIsSuspendedDAL);
}

BOOL BBCameraHookInstallSuspendedOnClasses(Class baseCls, Class tundraCls, Class dalCls) {
    SEL sel = @selector(isSuspended);
    Method baseMethod = baseCls ? class_getInstanceMethod(baseCls, sel) : NULL;
    BOOL hookedBase = NO;
    if (baseMethod) {
        IMP cur = method_getImplementation(baseMethod);
        if (cur != (IMP)bb_swizzled_isSuspended_base) {
            g_origIsSuspendedBase = method_setImplementation(baseMethod, (IMP)bb_swizzled_isSuspended_base);
            hookedBase = (g_origIsSuspendedBase != NULL);
        } else {
            hookedBase = YES;
        }
    }

    Method tundraMethod = tundraCls ? class_getInstanceMethod(tundraCls, sel) : NULL;
    BOOL hookedTundra = NO;
    if (tundraMethod && tundraMethod != baseMethod) {
        IMP cur = method_getImplementation(tundraMethod);
        if (cur != (IMP)bb_swizzled_isSuspended_tundra) {
            g_origIsSuspendedTundra = method_setImplementation(tundraMethod, (IMP)bb_swizzled_isSuspended_tundra);
            hookedTundra = (g_origIsSuspendedTundra != NULL);
        } else {
            hookedTundra = YES;
        }
    }

    Method dalMethod = dalCls ? class_getInstanceMethod(dalCls, sel) : NULL;
    BOOL hookedDal = NO;
    if (dalMethod && dalMethod != baseMethod && dalMethod != tundraMethod) {
        IMP cur = method_getImplementation(dalMethod);
        if (cur != (IMP)bb_swizzled_isSuspended_dal) {
            g_origIsSuspendedDAL = method_setImplementation(dalMethod, (IMP)bb_swizzled_isSuspended_dal);
            hookedDal = (g_origIsSuspendedDAL != NULL);
        } else {
            hookedDal = YES;
        }
    }

    os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: hooked isSuspended base=%d tundra=%d dal=%d",
                hookedBase ? 1 : 0, hookedTundra ? 1 : 0, hookedDal ? 1 : 0);
    return hookedBase || hookedTundra || hookedDal;
}

BOOL BBCameraHookInstallOnClasses(Class baseCls, Class tundraCls) {
    SEL sel = @selector(setSampleBufferDelegate:queue:);
    Method baseMethod = baseCls ? class_getInstanceMethod(baseCls, sel) : NULL;
    BOOL hookedBase = NO;
    if (baseMethod) {
        IMP cur = method_getImplementation(baseMethod);
        if (cur != (IMP)bb_swizzled_setSampleBufferDelegate) {
            g_origSetSampleBufferDelegate = method_setImplementation(baseMethod, (IMP)bb_swizzled_setSampleBufferDelegate);
            hookedBase = (g_origSetSampleBufferDelegate != NULL);
        } else {
            hookedBase = YES;
        }
    }

    Method tundraMethod = tundraCls ? class_getInstanceMethod(tundraCls, sel) : NULL;
    BOOL hookedTundra = NO;
    if (tundraMethod && tundraMethod != baseMethod) {
        IMP cur = method_getImplementation(tundraMethod);
        if (cur != (IMP)bb_swizzled_setSampleBufferDelegate_tundra) {
            g_origSetSampleBufferDelegateTundra = method_setImplementation(tundraMethod, (IMP)bb_swizzled_setSampleBufferDelegate_tundra);
            hookedTundra = (g_origSetSampleBufferDelegateTundra != NULL);
        } else {
            hookedTundra = YES;
        }
    }

    os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: hooked classes base=%{public}@ (%d) tundra=%{public}@ (%d)",
                baseCls ? NSStringFromClass(baseCls) : @"nil", hookedBase ? 1 : 0,
                tundraCls ? NSStringFromClass(tundraCls) : @"nil", hookedTundra ? 1 : 0);
    return hookedBase || hookedTundra;
}

typedef struct {
    int fd;
    void *map;
    size_t map_size;
    VTPixelTransferSessionRef transfer_session;
    CVPixelBufferPoolRef nv12_pool;
    uint32_t pool_w;
    uint32_t pool_h;
    char mapped_path[512];
} BBDownlinkRingWriter;

static os_unfair_lock g_downlink_lock = OS_UNFAIR_LOCK_INIT;
static BBDownlinkRingWriter g_downlink = {.fd = -1};
static IMP g_origShowDecodedFrame = NULL;
static IMP g_origReceivedRemoteFrame = NULL;
static IMP g_origNotifyRemoteFrame = NULL;
static IMP g_origVideoRelayEnqueue = NULL;
static IMP g_origBufferPoolAddFrame = NULL;
static IMP g_origReceiverDefaultInit = NULL;
static IMP g_origSetRemoteVideoAttributes = NULL;
static _Atomic uint32_t g_downlink_ori = 0;
static _Atomic bool g_downlink_has_ori = false;
#define BB_RECEIVER_VTABLE_MAX_ENTRIES 16
typedef struct {
    void *fns[BB_RECEIVER_VTABLE_MAX_ENTRIES];
} BBVideoReceiverVTable;
static const void *kBBOrigDidReceiveRemoteFrameKey = &kBBOrigDidReceiveRemoteFrameKey;
static os_unfair_lock g_receiver_vtable_lock = OS_UNFAIR_LOCK_INIT;
static BBVideoReceiverVTable g_wrappedReceiverVTable;
static _Atomic(void *) g_origDidReceiveRemoteFrame = NULL;

static void bb_downlink_unmap(BBDownlinkRingWriter *w) {
    if (w->map && w->map != MAP_FAILED) {
        munmap(w->map, w->map_size);
    }
    w->map = NULL;
    w->map_size = 0;
    if (w->fd >= 0) {
        close(w->fd);
        w->fd = -1;
    }
    if (w->transfer_session) {
        VTPixelTransferSessionInvalidate(w->transfer_session);
        CFRelease(w->transfer_session);
        w->transfer_session = NULL;
    }
    if (w->nv12_pool) {
        CVPixelBufferPoolRelease(w->nv12_pool);
        w->nv12_pool = NULL;
    }
    w->pool_w = 0;
    w->pool_h = 0;
    w->mapped_path[0] = '\0';
}

static BOOL bb_downlink_ensure_mapped(BBDownlinkRingWriter *w) {
    const char *path = g_downlinkRingPath ? g_downlinkRingPath : BB_DOWNLINK_RING_PATH;
    if (w->map && strcmp(w->mapped_path, path) == 0) {
        return YES;
    }
    bb_downlink_unmap(w);

    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0644);
    if (fd < 0) return NO;

    size_t totalSize = sizeof(BBCameraRingHeader) + (size_t)BB_DOWNLINK_RING_SLOTS * (size_t)BB_DOWNLINK_SLOT_BYTES;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (size_t)st.st_size < totalSize) {
        if (!S_ISREG(st.st_mode) || ftruncate(fd, (off_t)totalSize) != 0) {
            close(fd);
            return NO;
        }
    }

    void *map = mmap(NULL, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return NO;
    }

    BBCameraRingHeader *hdr = (BBCameraRingHeader *)map;
    if (hdr->magic != BB_RING_MAGIC || hdr->version != BB_RING_VERSION ||
        hdr->slots != BB_DOWNLINK_RING_SLOTS || hdr->slot_bytes != BB_DOWNLINK_SLOT_BYTES) {
        memset(hdr, 0, sizeof(*hdr));
        hdr->magic = BB_RING_MAGIC;
        hdr->version = BB_RING_VERSION;
        hdr->format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        hdr->slots = BB_DOWNLINK_RING_SLOTS;
        hdr->slot_bytes = BB_DOWNLINK_SLOT_BYTES;
        atomic_store_explicit(&hdr->seq, 0, memory_order_release);
    }

    w->fd = fd;
    w->map = map;
    w->map_size = totalSize;
    strlcpy(w->mapped_path, path, sizeof(w->mapped_path));
    return YES;
}

static CVPixelBufferRef bb_downlink_ensure_nv12(BBDownlinkRingWriter *w, CVPixelBufferRef src, uint32_t width, uint32_t height) {
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        return (CVPixelBufferRef)CFRetain(src);
    }
    if (!w->transfer_session) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &w->transfer_session) != noErr) {
            return NULL;
        }
    }
    if (!w->nv12_pool || w->pool_w != width || w->pool_h != height) {
        if (w->nv12_pool) {
            CVPixelBufferPoolRelease(w->nv12_pool);
            w->nv12_pool = NULL;
        }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &w->nv12_pool) != kCVReturnSuccess) {
            return NULL;
        }
        w->pool_w = width;
        w->pool_h = height;
    }
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, w->nv12_pool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    if (VTPixelTransferSessionTransferImage(w->transfer_session, src, dst) != noErr) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

static BOOL bb_extract_orientation(id videoAttrs, uint32_t *outOrientation) {
    if (!videoAttrs || !outOrientation) return NO;
    if ([videoAttrs respondsToSelector:@selector(orientation)]) {
        NSInteger ori = ((NSInteger (*)(id, SEL))objc_msgSend)(videoAttrs, @selector(orientation));
        if (ori >= 0 && ori <= 3) {
            *outOrientation = (uint32_t)ori;
            return YES;
        }
    }
    return NO;
}

BOOL BBCameraHookWriteDownlinkPixelBufferWithOrientation(CVPixelBufferRef frame, uint32_t orientation, BOOL hasOrientation) {
    if (!frame) return NO;
    size_t rawW = CVPixelBufferGetWidth(frame);
    size_t rawH = CVPixelBufferGetHeight(frame);
    uint32_t w = (uint32_t)(rawW & ~((size_t)1));
    uint32_t h = (uint32_t)(rawH & ~((size_t)1));
    if (w < 2 || h < 2 || w > BB_RING_MAX_DIM || h > BB_RING_MAX_DIM || ((uint64_t)w * (uint64_t)h) > BB_RING_MAX_PIXELS) {
        return NO;
    }

    if (!hasOrientation && atomic_load_explicit(&g_downlink_has_ori, memory_order_relaxed)) {
        orientation = atomic_load_explicit(&g_downlink_ori, memory_order_relaxed);
        hasOrientation = YES;
    }

    os_unfair_lock_lock(&g_downlink_lock);
    if (!bb_downlink_ensure_mapped(&g_downlink)) {
        os_unfair_lock_unlock(&g_downlink_lock);
        return NO;
    }

    CVPixelBufferRef nv12 = bb_downlink_ensure_nv12(&g_downlink, frame, w, h);
    if (!nv12) {
        os_unfair_lock_unlock(&g_downlink_lock);
        return NO;
    }

    BOOL ok = NO;
    if (CVPixelBufferLockBaseAddress(nv12, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        const uint8_t *ySrc = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
        const uint8_t *uvSrc = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
        size_t yBpr = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
        size_t uvBpr = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);
        size_t needed = (size_t)w * (size_t)h + (size_t)w * (size_t)(h / 2);
        if (ySrc && uvSrc && yBpr >= w && uvBpr >= w && needed <= BB_DOWNLINK_SLOT_BYTES) {
            BBCameraRingHeader *hdr = (BBCameraRingHeader *)g_downlink.map;
            uint64_t curSeq = atomic_load_explicit(&hdr->seq, memory_order_relaxed);
            if ((curSeq & 1ULL) != 0) {
                curSeq++;
            }
            uint64_t inProgressSeq = curSeq + 1;
            uint64_t doneSeq = curSeq + 2;
            atomic_store_explicit(&hdr->seq, inProgressSeq, memory_order_release);
            atomic_thread_fence(memory_order_release);

            uint32_t slotIdx = (uint32_t)(doneSeq % hdr->slots);
            uint8_t *slotPtr = (uint8_t *)g_downlink.map + sizeof(BBCameraRingHeader) + (size_t)slotIdx * (size_t)hdr->slot_bytes;
            uint8_t *yDst = slotPtr;
            for (uint32_t row = 0; row < h; row++) {
                memcpy(yDst + (size_t)row * w, ySrc + (size_t)row * yBpr, w);
            }
            uint8_t *uvDst = slotPtr + (size_t)w * (size_t)h;
            uint32_t uvRows = h / 2;
            for (uint32_t row = 0; row < uvRows; row++) {
                memcpy(uvDst + (size_t)row * w, uvSrc + (size_t)row * uvBpr, w);
            }
            hdr->width = w;
            hdr->height = h;
            hdr->stride = w;
            hdr->format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            hdr->ts_ns = bb_now_ns();
            hdr->orientation = hasOrientation ? (orientation & 0x03u) : 0u;
            hdr->flags = hasOrientation ? 1u : 0u;
            atomic_store_explicit(&hdr->seq, doneSeq, memory_order_release);
            ok = YES;
        }
        CVPixelBufferUnlockBaseAddress(nv12, kCVPixelBufferLock_ReadOnly);
    }
    CVPixelBufferRelease(nv12);
    os_unfair_lock_unlock(&g_downlink_lock);
    return ok;
}

BOOL BBCameraHookWriteDownlinkPixelBuffer(CVPixelBufferRef frame) {
    uint32_t ori = 0;
    BOOL hasOri = NO;
    if (atomic_load_explicit(&g_downlink_has_ori, memory_order_relaxed)) {
        ori = atomic_load_explicit(&g_downlink_ori, memory_order_relaxed);
        hasOri = YES;
    }
    return BBCameraHookWriteDownlinkPixelBufferWithOrientation(frame, ori, hasOri);
}

static int bb_swizzled_showDecodedFrame(id self, SEL _cmd, CVPixelBufferRef frame, CMTime time) {
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: capturing decoded downlink stream (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
        uint32_t ori = 0;
        BOOL hasOri = NO;
        if (self && [self respondsToSelector:@selector(remoteVideoAttributes)]) {
            id attrs = ((id (*)(id, SEL))objc_msgSend)(self, @selector(remoteVideoAttributes));
            hasOri = bb_extract_orientation(attrs, &ori);
        }
        if (!hasOri && atomic_load_explicit(&g_downlink_has_ori, memory_order_relaxed)) {
            ori = atomic_load_explicit(&g_downlink_ori, memory_order_relaxed);
            hasOri = YES;
        }
        BBCameraHookWriteDownlinkPixelBufferWithOrientation(frame, ori, hasOri);
    }
    if (g_origShowDecodedFrame) {
        return ((int (*)(id, SEL, CVPixelBufferRef, CMTime))g_origShowDecodedFrame)(self, _cmd, frame, time);
    }
    return 0;
}

static BOOL bb_swizzled_receivedRemoteFrame(id self, SEL _cmd, id session, CVPixelBufferRef frame, CMTime time, id screenAttrs, id videoAttrs, BOOL isFirst, BOOL isPaused) {
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VideoConference receivedRemoteFrame (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
        uint32_t ori = 0;
        BOOL hasOri = bb_extract_orientation(videoAttrs, &ori);
        BBCameraHookWriteDownlinkPixelBufferWithOrientation(frame, ori, hasOri);
    }
    if (g_origReceivedRemoteFrame) {
        return ((BOOL (*)(id, SEL, id, CVPixelBufferRef, CMTime, id, id, BOOL, BOOL))g_origReceivedRemoteFrame)(
            self, _cmd, session, frame, time, screenAttrs, videoAttrs, isFirst, isPaused);
    }
    return NO;
}

static void bb_swizzled_notifyRemoteFrame(id self, SEL _cmd, CVPixelBufferRef frame, CMTime time, uint8_t camBits, id videoAttrs, id screenAttrs) {
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VCCallSession notifyRemoteFrame (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
        uint32_t ori = 0;
        BOOL hasOri = bb_extract_orientation(videoAttrs, &ori);
        if (!hasOri) {
            ori = (uint32_t)(camBits & 0x03u);
            hasOri = YES;
        }
        BBCameraHookWriteDownlinkPixelBufferWithOrientation(frame, ori, hasOri);
    }
    if (g_origNotifyRemoteFrame) {
        ((void (*)(id, SEL, CVPixelBufferRef, CMTime, uint8_t, id, id))g_origNotifyRemoteFrame)(
            self, _cmd, frame, time, camBits, videoAttrs, screenAttrs);
    }
}

static BOOL bb_swizzled_videoRelayEnqueue(id self, SEL _cmd, CVPixelBufferRef frame, CMTime time, uint8_t camBits) {
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VCVideoRelay enqueueFrame (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
    }
    if (g_origVideoRelayEnqueue) {
        return ((BOOL (*)(id, SEL, CVPixelBufferRef, CMTime, uint8_t))g_origVideoRelayEnqueue)(self, _cmd, frame, time, camBits);
    }
    return NO;
}

static BOOL bb_swizzled_bufferPoolAddFrame(id self, SEL _cmd, CVPixelBufferRef frame, int64_t time) {
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VCVideoFrameBufferPool addFrame (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
    }
    if (g_origBufferPoolAddFrame) {
        return ((BOOL (*)(id, SEL, CVPixelBufferRef, int64_t))g_origBufferPoolAddFrame)(self, _cmd, frame, time);
    }
    return NO;
}

static uint64_t bb_didReceiveRemoteFrame(id self, CVPixelBufferRef frame, const void *cmTimePtr, id a3, id a4, uintptr_t a5) {
    if (frame != NULL) {
        CVPixelBufferRetain(frame);
    }
    void *origFn = NULL;
    if (self) {
        NSValue *val = objc_getAssociatedObject(self, kBBOrigDidReceiveRemoteFrameKey);
        if (val) {
            origFn = [val pointerValue];
        }
    }
    if (!origFn) {
        origFn = atomic_load_explicit(&g_origDidReceiveRemoteFrame, memory_order_acquire);
    }
    uint64_t ret = 0;
    if (origFn) {
        ret = ((uint64_t (*)(id, CVPixelBufferRef, const void *, id, id, uintptr_t))origFn)(
            self, frame, cmTimePtr, a3, a4, a5);
    }
    if (frame != NULL) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: capturing VCVideoStream decoded remote frame (%zux%zu)",
                        CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
        });
        uint32_t ori = 0;
        BOOL hasOri = NO;
        // Read _videoReceiver.remoteVideoAttributes after origFn updates it
        if (self) {
            Ivar vrIvar = class_getInstanceVariable([self class], "_videoReceiver");
            id vr = vrIvar ? object_getIvar(self, vrIvar) : nil;
            if (vr && [vr respondsToSelector:@selector(remoteVideoAttributes)]) {
                id attrs = ((id (*)(id, SEL))objc_msgSend)(vr, @selector(remoteVideoAttributes));
                hasOri = bb_extract_orientation(attrs, &ori);
            }
        }
        if (!hasOri && self && [self respondsToSelector:@selector(remoteVideoAttributes)]) {
            id attrs = ((id (*)(id, SEL))objc_msgSend)(self, @selector(remoteVideoAttributes));
            hasOri = bb_extract_orientation(attrs, &ori);
        }
        if (!hasOri && atomic_load_explicit(&g_downlink_has_ori, memory_order_relaxed)) {
            ori = atomic_load_explicit(&g_downlink_ori, memory_order_relaxed);
            hasOri = YES;
        }
        BBCameraHookWriteDownlinkPixelBufferWithOrientation(frame, ori, hasOri);
        CVPixelBufferRelease(frame);
    }
    return ret;
}

static void bb_record_remote_attrs(id attrs) {
    uint32_t ori = 0;
    if (bb_extract_orientation(attrs, &ori)) {
        atomic_store_explicit(&g_downlink_ori, ori, memory_order_relaxed);
        atomic_store_explicit(&g_downlink_has_ori, true, memory_order_relaxed);
        os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: remoteVideoAttributes ori=%u", ori);
    }
}

static void bb_swizzled_setRemoteVideoAttributes(id self, SEL _cmd, id attrs) {
    bb_record_remote_attrs(attrs);
    if (g_origSetRemoteVideoAttributes) {
        ((void (*)(id, SEL, id))g_origSetRemoteVideoAttributes)(self, _cmd, attrs);
    }
}

static id bb_swizzled_receiverDefaultInit(id self, SEL _cmd, void *cfg, id delegate, void *fns, void *rep, id stats, void *tx, id sca) {
    void *effectiveFns = fns;
    if (fns != NULL) {
        void **srcFns = (void **)fns;
        void *origFn1 = srcFns[1];
        if (origFn1 != NULL && origFn1 != (void *)bb_didReceiveRemoteFrame) {
            os_unfair_lock_lock(&g_receiver_vtable_lock);
            g_wrappedReceiverVTable.fns[0] = srcFns[0];
            g_wrappedReceiverVTable.fns[1] = (void *)bb_didReceiveRemoteFrame;
            atomic_store_explicit(&g_origDidReceiveRemoteFrame, origFn1, memory_order_release);
            os_unfair_lock_unlock(&g_receiver_vtable_lock);
            if (delegate) {
                objc_setAssociatedObject(delegate, kBBOrigDidReceiveRemoteFrameKey, [NSValue valueWithPointer:origFn1], OBJC_ASSOCIATION_RETAIN);
            }
            effectiveFns = g_wrappedReceiverVTable.fns;
        } else if (origFn1 == (void *)bb_didReceiveRemoteFrame && g_wrappedReceiverVTable.fns[1] == (void *)bb_didReceiveRemoteFrame) {
            effectiveFns = g_wrappedReceiverVTable.fns;
        }
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VCVideoReceiverDefault init delegate=%{public}@ fns=%p wrapped=%d",
                    delegate ? NSStringFromClass([delegate class]) : @"(nil)", fns, effectiveFns == g_wrappedReceiverVTable.fns);
    });
    if (g_origReceiverDefaultInit) {
        id res = ((id (*)(id, SEL, void *, id, void *, void *, id, void *, id))g_origReceiverDefaultInit)(
            self, _cmd, cfg, delegate, effectiveFns, rep, stats, tx, sca);
        if (res && [res respondsToSelector:@selector(remoteVideoAttributes)]) {
            bb_record_remote_attrs(((id (*)(id, SEL))objc_msgSend)(res, @selector(remoteVideoAttributes)));
        }
        return res;
    }
    return nil;
}

BOOL BBCameraHookInstallDownlinkOnClass(Class receiverCls) {
    SEL sel = @selector(showDecodedFrame:atTime:);
    Method m = receiverCls ? class_getInstanceMethod(receiverCls, sel) : NULL;
    if (!m) {
        os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: VCVideoStreamReceiver showDecodedFrame:atTime: not found");
        return NO;
    }
    if (method_getImplementation(m) != (IMP)bb_swizzled_showDecodedFrame) {
        g_origShowDecodedFrame = method_setImplementation(m, (IMP)bb_swizzled_showDecodedFrame);
    }
    os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: hooked downlink stream on %{public}@ (%d)",
                NSStringFromClass(receiverCls), g_origShowDecodedFrame != NULL ? 1 : 0);

    Class vcCls = objc_getClass("VideoConference");
    Method mVC = vcCls ? class_getInstanceMethod(vcCls, @selector(session:receivedRemoteFrame:atTime:withScreenAttributes:videoAttributes:isFirstFrame:isVideoPaused:)) : NULL;
    if (mVC && method_getImplementation(mVC) != (IMP)bb_swizzled_receivedRemoteFrame) {
        g_origReceivedRemoteFrame = method_setImplementation(mVC, (IMP)bb_swizzled_receivedRemoteFrame);
    }

    Class csCls = objc_getClass("VCCallSession");
    Method mCS = csCls ? class_getInstanceMethod(csCls, @selector(nofityDelegateReceivedRemoteFrame:frameTime:cameraStatusBits:newRemoteVideoAttributes:remoteScreenAttributes:)) : NULL;
    if (mCS && method_getImplementation(mCS) != (IMP)bb_swizzled_notifyRemoteFrame) {
        g_origNotifyRemoteFrame = method_setImplementation(mCS, (IMP)bb_swizzled_notifyRemoteFrame);
    }

    Class vrCls = objc_getClass("VCVideoRelay");
    Method mVR = vrCls ? class_getInstanceMethod(vrCls, @selector(enqueueFrame:atTime:cameraStatusBits:)) : NULL;
    if (mVR && method_getImplementation(mVR) != (IMP)bb_swizzled_videoRelayEnqueue) {
        g_origVideoRelayEnqueue = method_setImplementation(mVR, (IMP)bb_swizzled_videoRelayEnqueue);
    }

    Class bpCls = objc_getClass("VCVideoFrameBufferPool");
    Method mBP = bpCls ? class_getInstanceMethod(bpCls, @selector(addFrame:time:)) : NULL;
    if (mBP && method_getImplementation(mBP) != (IMP)bb_swizzled_bufferPoolAddFrame) {
        g_origBufferPoolAddFrame = method_setImplementation(mBP, (IMP)bb_swizzled_bufferPoolAddFrame);
    }

    Class rdCls = objc_getClass("VCVideoReceiverDefault");
    Method mRD = rdCls ? class_getInstanceMethod(rdCls, @selector(initWithConfig:delegate:delegateFunctions:reportingAgent:statisticsCollector:transmitterHandle:sensitiveContentAnalyzer:)) : NULL;
    if (mRD && method_getImplementation(mRD) != (IMP)bb_swizzled_receiverDefaultInit) {
        g_origReceiverDefaultInit = method_setImplementation(mRD, (IMP)bb_swizzled_receiverDefaultInit);
    }
    Method mRDA = rdCls ? class_getInstanceMethod(rdCls, @selector(setRemoteVideoAttributes:)) : NULL;
    if (mRDA && method_getImplementation(mRDA) != (IMP)bb_swizzled_setRemoteVideoAttributes) {
        g_origSetRemoteVideoAttributes = method_setImplementation(mRDA, (IMP)bb_swizzled_setRemoteVideoAttributes);
    }

    os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: extra hooks vc=%d cs=%d vr=%d bp=%d rd=%d",
                mVC != NULL, mCS != NULL, mVR != NULL, mBP != NULL, mRD != NULL);
    return g_origShowDecodedFrame != NULL;
}

#define BB_DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _bb_interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

static bool bb_is_avconferenced(void) {
    const char *prog = getprogname();
    return prog && strcmp(prog, "avconferenced") == 0;
}

static bool bb_audio_unit_input_is_blackhole(AudioUnit unit) {
    AudioDeviceID devID = kAudioObjectUnknown;
    UInt32 devSize = sizeof(devID);
    OSStatus st = AudioUnitGetProperty(
        unit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        1,
        &devID,
        &devSize);
    if (st != noErr || devID == kAudioObjectUnknown) {
        devSize = sizeof(devID);
        st = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Input,
            1,
            &devID,
            &devSize);
    }
    if (st != noErr || devID == kAudioObjectUnknown) {
        return false;
    }

    CFStringRef uid = NULL;
    UInt32 uidSize = sizeof(uid);
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(devID, &addr, 0, NULL, &uidSize, &uid) == noErr && uid != NULL) {
        Boolean found = CFStringFind(uid, CFSTR("BlackHole"), 0).location != kCFNotFound;
        CFRelease(uid);
        return found;
    }
    return false;
}

static bool bb_should_bypass_vpio(AudioUnit unit) {
    if (!unit) return false;
    AudioComponent comp = AudioComponentInstanceGetComponent((AudioComponentInstance)unit);
    if (!comp) return false;
    AudioComponentDescription desc = {0};
    if (AudioComponentGetDescription(comp, &desc) != noErr) return false;
    if (desc.componentType != kAudioUnitType_Output ||
        desc.componentSubType != kAudioUnitSubType_VoiceProcessingIO) {
        return false;
    }
    if (access(g_activeFlagPath, F_OK) == 0) {
        return true;
    }
    return bb_audio_unit_input_is_blackhole(unit);
}

BOOL BBCameraHookShouldBypassVPIO(AudioUnit unit) {
    return bb_should_bypass_vpio(unit);
}

static OSStatus bb_AudioUnitInitialize(AudioUnit inUnit) {
    if (bb_is_avconferenced() && bb_should_bypass_vpio(inUnit)) {
        UInt32 bypass = 1;
        OSStatus bypassStatus = AudioUnitSetProperty(
            inUnit,
            kAUVoiceIOProperty_BypassVoiceProcessing,
            kAudioUnitScope_Global,
            0,
            &bypass,
            sizeof(bypass));
        os_log_info(OS_LOG_DEFAULT,
                    "BlueBubblesCameraHook: AudioUnitInitialize VPIO bypass=1 unit=%p status=%d",
                    inUnit, (int)bypassStatus);
    }
    return AudioUnitInitialize(inUnit);
}

static OSStatus bb_AudioUnitSetProperty(
    AudioUnit inUnit,
    AudioUnitPropertyID inID,
    AudioUnitScope inScope,
    AudioUnitElement inElement,
    const void *inData,
    UInt32 inDataSize) {
    UInt32 one = 1;
    if (bb_is_avconferenced() &&
        inID == kAUVoiceIOProperty_BypassVoiceProcessing &&
        bb_should_bypass_vpio(inUnit)) {
        inData = &one;
        inDataSize = sizeof(one);
        os_log_info(OS_LOG_DEFAULT,
                    "BlueBubblesCameraHook: AudioUnitSetProperty forced VPIO bypass=1 unit=%p",
                    inUnit);
    }
    return AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

BB_DYLD_INTERPOSE(bb_AudioUnitInitialize, AudioUnitInitialize)
BB_DYLD_INTERPOSE(bb_AudioUnitSetProperty, AudioUnitSetProperty)

static IMP g_origSupportsPortraitResolution = NULL;
static IMP g_origTransmitterInitWithConfig = NULL;
static IMP g_origTransmitterStartVideo = NULL;
static IMP g_origVideoPresentationOrientation = NULL;
static IMP g_origVideoPresentationOrientationLocal = NULL;
static IMP g_origSetVideoPresentationOrientation = NULL;
static IMP g_origSetLocalVideoAttributesCameraSessionType = NULL;
static IMP g_origSessionDidChangeDeviceOrientation = NULL;
static IMP g_origSessionDidChangeVideoPresentationOrientation = NULL;
static IMP g_origNegLocalDeviceInitialOrientation = NULL;
static IMP g_origNegLocalSetDeviceInitialOrientation = NULL;
static IMP g_origNegLocalDedicatedOriEnabled = NULL;
static IMP g_origNegLocalSetDedicatedOriEnabled = NULL;
static IMP g_origNegU1DeviceInitialOrientation = NULL;
static IMP g_origNegU1SetDeviceInitialOrientation = NULL;
static IMP g_origBlobDeviceOrientation = NULL;
static IMP g_origBlobSetDeviceOrientation = NULL;
static atomic_int g_uplink_orientation = -1;

static int bb_active_uplink_orientation(void) {
    if (!bb_should_unsuspend_camera()) return -1;
    int ori = atomic_load_explicit(&g_uplink_orientation, memory_order_relaxed);
    return (ori >= 0) ? ori : 0;
}

static int bb_swizzled_videoPresentationOrientation(id self, SEL _cmd) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) return targetOri;
    return g_origVideoPresentationOrientation
        ? ((int (*)(id, SEL))g_origVideoPresentationOrientation)(self, _cmd)
        : 0;
}

static int bb_swizzled_videoPresentationOrientationLocal(id self, SEL _cmd) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) return targetOri;
    return g_origVideoPresentationOrientationLocal
        ? ((int (*)(id, SEL))g_origVideoPresentationOrientationLocal)(self, _cmd)
        : 0;
}

static void bb_swizzled_setVideoPresentationOrientation(id self, SEL _cmd, int ori, int src) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) ori = targetOri;
    if (g_origSetVideoPresentationOrientation) {
        ((void (*)(id, SEL, int, int))g_origSetVideoPresentationOrientation)(self, _cmd, ori, src);
    }
}

static void bb_swizzled_sessionDidChangeDeviceOrientation(id self, SEL _cmd, id participant, int ori) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) ori = targetOri;
    if (g_origSessionDidChangeDeviceOrientation) {
        ((void (*)(id, SEL, id, int))g_origSessionDidChangeDeviceOrientation)(self, _cmd, participant, ori);
    }
}

static void bb_swizzled_sessionDidChangeVideoPresentationOrientation(id self, SEL _cmd, id participant, int ori) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) ori = targetOri;
    if (g_origSessionDidChangeVideoPresentationOrientation) {
        ((void (*)(id, SEL, id, int))g_origSessionDidChangeVideoPresentationOrientation)(self, _cmd, participant, ori);
    }
}

static int bb_swizzled_negLocalDeviceInitialOrientation(id self, SEL _cmd) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) return targetOri;
    return g_origNegLocalDeviceInitialOrientation
        ? ((int (*)(id, SEL))g_origNegLocalDeviceInitialOrientation)(self, _cmd)
        : 0;
}

static void bb_swizzled_negLocalSetDeviceInitialOrientation(id self, SEL _cmd, int ori) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: negLocal setDeviceInitialOrientation %d -> %d", ori, targetOri);
        });
        ori = targetOri;
    }
    if (g_origNegLocalSetDeviceInitialOrientation) {
        ((void (*)(id, SEL, int))g_origNegLocalSetDeviceInitialOrientation)(self, _cmd, ori);
    }
}

static BOOL bb_swizzled_negLocalDedicatedOriEnabled(id self, SEL _cmd) {
    if (bb_active_uplink_orientation() >= 0) return YES;
    return g_origNegLocalDedicatedOriEnabled
        ? ((BOOL (*)(id, SEL))g_origNegLocalDedicatedOriEnabled)(self, _cmd)
        : NO;
}

static void bb_swizzled_negLocalSetDedicatedOriEnabled(id self, SEL _cmd, BOOL enabled) {
    if (bb_active_uplink_orientation() >= 0) enabled = YES;
    if (g_origNegLocalSetDedicatedOriEnabled) {
        ((void (*)(id, SEL, BOOL))g_origNegLocalSetDedicatedOriEnabled)(self, _cmd, enabled);
    }
}

static int bb_swizzled_negU1DeviceInitialOrientation(id self, SEL _cmd) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) return targetOri;
    return g_origNegU1DeviceInitialOrientation
        ? ((int (*)(id, SEL))g_origNegU1DeviceInitialOrientation)(self, _cmd)
        : 0;
}

static void bb_swizzled_negU1SetDeviceInitialOrientation(id self, SEL _cmd, int ori) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) ori = targetOri;
    if (g_origNegU1SetDeviceInitialOrientation) {
        ((void (*)(id, SEL, int))g_origNegU1SetDeviceInitialOrientation)(self, _cmd, ori);
    }
}

static int bb_swizzled_blobDeviceOrientation(id self, SEL _cmd) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) return targetOri;
    return g_origBlobDeviceOrientation
        ? ((int (*)(id, SEL))g_origBlobDeviceOrientation)(self, _cmd)
        : 0;
}

static void bb_swizzled_blobSetDeviceOrientation(id self, SEL _cmd, int ori) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0) ori = targetOri;
    if (g_origBlobSetDeviceOrientation) {
        ((void (*)(id, SEL, int))g_origBlobSetDeviceOrientation)(self, _cmd, ori);
    }
}

static id bb_swizzled_transmitterInitWithConfig(id self, SEL _cmd, id config) {
    if (config && bb_should_unsuspend_camera()) {
        @try {
            [config setValue:@YES forKey:@"reinitEncoderOnFrameAspectRatioChangeEnabled"];
            [config setValue:@YES forKey:@"reinitEncoderOnFrameSizeChangeEnabled"];
            id res = [config valueForKey:@"videoResolution"];
            id cw = [config valueForKey:@"customWidth"];
            id ch = [config valueForKey:@"customHeight"];
            id cvo = [config valueForKey:@"enableCVO"];
            id cvoExt = [config valueForKey:@"cvoExtensionID"];
            id reinitAR = [config valueForKey:@"reinitEncoderOnFrameAspectRatioChangeEnabled"];
            os_log_info(OS_LOG_DEFAULT,
                        "BlueBubblesCameraHook: transmitter initWithConfig res=%@ custom=%@x%@ cvo=%@ cvoExt=%@ reinitAR=%@ ori=%d",
                        res, cw, ch, cvo, cvoExt, reinitAR,
                        atomic_load_explicit(&g_uplink_orientation, memory_order_relaxed));
        } @catch (NSException *ignored) {}
    }
    if (g_origTransmitterInitWithConfig) {
        return ((id (*)(id, SEL, id))g_origTransmitterInitWithConfig)(self, _cmd, config);
    }
    return self;
}

static void bb_pin_video_attributes(id attrs, int targetOri) {
    ((void (*)(id, SEL, int))objc_msgSend)(attrs, @selector(setOrientation:), targetOri);
    if ((targetOri == 0 || targetOri == 1) &&
        [attrs respondsToSelector:@selector(ratio)] &&
        [attrs respondsToSelector:@selector(setRatio:)]) {
        CGSize r = ((CGSize (*)(id, SEL))objc_msgSend)(attrs, @selector(ratio));
        if (r.width > r.height) {
            ((void (*)(id, SEL, CGSize))objc_msgSend)(attrs, @selector(setRatio:), CGSizeMake(r.height, r.width));
        }
    }
}

static BOOL bb_swizzled_setLocalVideoAttributesCameraSessionType(id self, SEL _cmd, id attrs, int sessionType) {
    int targetOri = bb_active_uplink_orientation();
    if (targetOri >= 0 && attrs && [attrs respondsToSelector:@selector(setOrientation:)]) {
        id pinned = [attrs copy];
        if (pinned) {
            attrs = pinned;
        }
        bb_pin_video_attributes(attrs, targetOri);
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            os_log_info(OS_LOG_DEFAULT,
                        "BlueBubblesCameraHook: pinned localVideoAttributes orientation=%d (sessionType=%d)",
                        targetOri, sessionType);
        });
    }
    if (g_origSetLocalVideoAttributesCameraSessionType) {
        return ((BOOL (*)(id, SEL, id, int))g_origSetLocalVideoAttributesCameraSessionType)(self, _cmd, attrs, sessionType);
    }
    return NO;
}

static void bb_apply_uplink_orientation_to_server(int targetOri) {
    Class cls = objc_getClass("VCVideoCaptureServer");
    if (!cls || ![cls respondsToSelector:@selector(VCVideoCaptureServerSingleton)]) return;
    id srv = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(VCVideoCaptureServerSingleton));
    if (!srv) return;
    if ([srv respondsToSelector:@selector(localVideoAttributes)] &&
        [srv respondsToSelector:@selector(setLocalVideoAttributes:)]) {
        id curAttrs = ((id (*)(id, SEL))objc_msgSend)(srv, @selector(localVideoAttributes));
        if (curAttrs) {
            id attrs = [curAttrs copy];
            if (attrs && [attrs respondsToSelector:@selector(setOrientation:)]) {
                bb_pin_video_attributes(attrs, targetOri);
                ((BOOL (*)(id, SEL, id))objc_msgSend)(srv, @selector(setLocalVideoAttributes:), attrs);
            }
        }
    }
    if ([srv respondsToSelector:@selector(notifyDeviceStateDelegatesWithDeviceOrientationChanged:)]) {
        ((void (*)(id, SEL, int))objc_msgSend)(srv, @selector(notifyDeviceStateDelegatesWithDeviceOrientationChanged:), targetOri);
    }
    if ([srv respondsToSelector:@selector(notifyDeviceStateDelegatesVideoPresentationOrientationChanged:)]) {
        ((void (*)(id, SEL, int))objc_msgSend)(srv, @selector(notifyDeviceStateDelegatesVideoPresentationOrientationChanged:), targetOri);
    }
}

static BOOL bb_swizzled_supportsPortraitResolution(id self, SEL _cmd) {
    if (bb_should_unsuspend_camera()) {
        return YES;
    }
    if (g_origSupportsPortraitResolution) {
        return ((BOOL (*)(id, SEL))g_origSupportsPortraitResolution)(self, _cmd);
    }
    return NO;
}

static void bb_swizzled_transmitterStartVideo(id self, SEL _cmd) {
    if (g_origTransmitterStartVideo) {
        ((void (*)(id, SEL))g_origTransmitterStartVideo)(self, _cmd);
    }
    int targetOri = atomic_load_explicit(&g_uplink_orientation, memory_order_relaxed);
    if (targetOri >= 0 && bb_should_unsuspend_camera()) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            bb_apply_uplink_orientation_to_server(targetOri);
            if ([self respondsToSelector:@selector(onLocalDeviceOrientationDidChange)]) {
                ((void (*)(id, SEL))objc_msgSend)(self, @selector(onLocalDeviceOrientationDidChange));
            }
            os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: re-applied orientation=%d on VCVideoTransmitterDefault startVideo", targetOri);
        });
    }
}

static void bb_notify_uplink_orientation(uint32_t w, uint32_t h) {
    int targetOri = (h > w) ? 0 : 2; // 0=Portrait, 2=LandscapeLeft
    int prev = atomic_exchange_explicit(&g_uplink_orientation, targetOri, memory_order_relaxed);
    if (prev == targetOri) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bb_apply_uplink_orientation_to_server(targetOri);
        os_log_info(OS_LOG_DEFAULT, "BlueBubblesCameraHook: updated VCVideoCaptureServer orientation=%d (%ux%u)", targetOri, w, h);
    });
}

__attribute__((constructor))
static void bb_camera_hook_init(void) {
    if (!bb_is_avconferenced()) {
        return;
    }

    BBCameraHookInstallOnClasses(
        objc_getClass("AVCaptureVideoDataOutput"),
        objc_getClass("AVCaptureVideoDataOutput_Tundra"));
    BBCameraHookInstallSuspendedOnClasses(
        objc_getClass("AVCaptureDevice"),
        objc_getClass("AVCaptureDevice_Tundra"),
        objc_getClass("AVCaptureDALDevice"));
    BBCameraHookInstallDownlinkOnClass(objc_getClass("VCVideoStreamReceiver"));

    Class captureServerCls = objc_getClass("VCVideoCaptureServer");
    if (captureServerCls) {
        struct { SEL sel; IMP imp; IMP *orig; } hooks[] = {
            {@selector(supportsPortraitResolution), (IMP)bb_swizzled_supportsPortraitResolution, &g_origSupportsPortraitResolution},
            {@selector(videoPresentationOrientation), (IMP)bb_swizzled_videoPresentationOrientation, &g_origVideoPresentationOrientation},
            {@selector(videoPresentationOrientationLocal), (IMP)bb_swizzled_videoPresentationOrientationLocal, &g_origVideoPresentationOrientationLocal},
            {@selector(setVideoPresentationOrientation:source:), (IMP)bb_swizzled_setVideoPresentationOrientation, &g_origSetVideoPresentationOrientation},
            {@selector(setLocalVideoAttributes:cameraSessionType:), (IMP)bb_swizzled_setLocalVideoAttributesCameraSessionType, &g_origSetLocalVideoAttributesCameraSessionType},
        };
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(captureServerCls, hooks[i].sel);
            if (m && method_getImplementation(m) != hooks[i].imp) {
                *(hooks[i].orig) = method_setImplementation(m, hooks[i].imp);
            }
        }
    }

    Class sessionCls = objc_getClass("VCSession");
    if (sessionCls) {
        struct { SEL sel; IMP imp; IMP *orig; } hooks[] = {
            {@selector(vcSessionParticipant:didChangeDeviceOrientation:), (IMP)bb_swizzled_sessionDidChangeDeviceOrientation, &g_origSessionDidChangeDeviceOrientation},
            {@selector(vcSessionParticipant:didChangeVideoPresentationOrientation:), (IMP)bb_swizzled_sessionDidChangeVideoPresentationOrientation, &g_origSessionDidChangeVideoPresentationOrientation},
        };
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(sessionCls, hooks[i].sel);
            if (m && method_getImplementation(m) != hooks[i].imp) {
                *(hooks[i].orig) = method_setImplementation(m, hooks[i].imp);
            }
        }
    }

    Class negLocalCls = objc_getClass("VCMediaNegotiatorLocalConfiguration");
    if (negLocalCls) {
        struct { SEL sel; IMP imp; IMP *orig; } hooks[] = {
            {@selector(deviceInitialOrientation), (IMP)bb_swizzled_negLocalDeviceInitialOrientation, &g_origNegLocalDeviceInitialOrientation},
            {@selector(setDeviceInitialOrientation:), (IMP)bb_swizzled_negLocalSetDeviceInitialOrientation, &g_origNegLocalSetDeviceInitialOrientation},
            {@selector(isDedicatedVideoPresentationOrientationEnabled), (IMP)bb_swizzled_negLocalDedicatedOriEnabled, &g_origNegLocalDedicatedOriEnabled},
            {@selector(setIsDedicatedVideoPresentationOrientationEnabled:), (IMP)bb_swizzled_negLocalSetDedicatedOriEnabled, &g_origNegLocalSetDedicatedOriEnabled},
        };
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(negLocalCls, hooks[i].sel);
            if (m && method_getImplementation(m) != hooks[i].imp) {
                *(hooks[i].orig) = method_setImplementation(m, hooks[i].imp);
            }
        }
    }

    Class negU1Cls = objc_getClass("VCMediaNegotiatorStreamGroupU1Configuration");
    if (negU1Cls) {
        struct { SEL sel; IMP imp; IMP *orig; } hooks[] = {
            {@selector(deviceInitialOrientation), (IMP)bb_swizzled_negU1DeviceInitialOrientation, &g_origNegU1DeviceInitialOrientation},
            {@selector(setDeviceInitialOrientation:), (IMP)bb_swizzled_negU1SetDeviceInitialOrientation, &g_origNegU1SetDeviceInitialOrientation},
        };
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(negU1Cls, hooks[i].sel);
            if (m && method_getImplementation(m) != hooks[i].imp) {
                *(hooks[i].orig) = method_setImplementation(m, hooks[i].imp);
            }
        }
    }

    Class blobCamCls = objc_getClass("VCMediaNegotiationBlobV2CameraSettingsU1");
    if (blobCamCls) {
        struct { SEL sel; IMP imp; IMP *orig; } hooks[] = {
            {@selector(deviceOrientation), (IMP)bb_swizzled_blobDeviceOrientation, &g_origBlobDeviceOrientation},
            {@selector(setDeviceOrientation:), (IMP)bb_swizzled_blobSetDeviceOrientation, &g_origBlobSetDeviceOrientation},
        };
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
            Method m = class_getInstanceMethod(blobCamCls, hooks[i].sel);
            if (m && method_getImplementation(m) != hooks[i].imp) {
                *(hooks[i].orig) = method_setImplementation(m, hooks[i].imp);
            }
        }
    }

    Class transmitterCls = objc_getClass("VCVideoTransmitterDefault");
    if (transmitterCls) {
        Method mInit = class_getInstanceMethod(transmitterCls, @selector(initWithConfig:));
        if (mInit) {
            IMP curInit = method_getImplementation(mInit);
            if (curInit != (IMP)bb_swizzled_transmitterInitWithConfig) {
                g_origTransmitterInitWithConfig = method_setImplementation(mInit, (IMP)bb_swizzled_transmitterInitWithConfig);
            }
        }
        Method m = class_getInstanceMethod(transmitterCls, @selector(startVideo));
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)bb_swizzled_transmitterStartVideo) {
                g_origTransmitterStartVideo = method_setImplementation(m, (IMP)bb_swizzled_transmitterStartVideo);
            }
        }
    }
}
