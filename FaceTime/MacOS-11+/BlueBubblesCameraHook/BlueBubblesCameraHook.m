#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

#define BB_RING_PATH "/private/tmp/FaceTime/bb-camera.ring"
#define BB_RING_MAGIC 0x42424352u // 'BBCR'
#define BB_RING_VERSION 1u
#define BB_RING_MAX_WIDTH 1280u
#define BB_RING_MAX_HEIGHT 720u
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
    uint8_t reserved[16];
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

CMSampleBufferRef BBCameraHookCreateSwappedSampleBuffer(CMSampleBufferRef origSampleBuffer, const char *ringPath) {
    if (!origSampleBuffer || !ringPath) return NULL;

    CVImageBufferRef origImg = CMSampleBufferGetImageBuffer(origSampleBuffer);
    if (!origImg) return NULL;

    uint32_t dstW = (uint32_t)CVPixelBufferGetWidth(origImg);
    uint32_t dstH = (uint32_t)CVPixelBufferGetHeight(origImg);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(origImg);
    if (dstW == 0 || dstH == 0) return NULL;

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
        w == 0 || w > BB_RING_MAX_WIDTH || h == 0 || h > BB_RING_MAX_HEIGHT ||
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
    if (!g_reader.transfer_session) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &g_reader.transfer_session);
    }

    if (!g_reader.src_pool || !g_reader.dst_pool || !g_reader.transfer_session) {
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

    CVPixelBufferRef dstBuf = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_reader.dst_pool, &dstBuf) != kCVReturnSuccess || !dstBuf) {
        CFRelease(srcBuf);
        os_unfair_lock_unlock(&g_reader_lock);
        return NULL;
    }

    VTPixelTransferSessionRef xfer = (VTPixelTransferSessionRef)CFRetain(g_reader.transfer_session);
    os_unfair_lock_unlock(&g_reader_lock);

    OSStatus xferStatus = VTPixelTransferSessionTransferImage(xfer, srcBuf, dstBuf);
    CFRelease(xfer);
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

    CMSampleTimingInfo timing = kCMTimingInfoInvalid;
    if (CMSampleBufferGetSampleTimingInfo(origSampleBuffer, 0, &timing) != noErr) {
        CFRelease(fmtDesc);
        CFRelease(dstBuf);
        return NULL;
    }

    CMSampleBufferRef outSample = NULL;
    OSStatus sbStatus = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, dstBuf, fmtDesc, &timing, &outSample);
    CFRelease(fmtDesc);
    CFRelease(dstBuf);

    if (sbStatus != noErr) {
        if (outSample) CFRelease(outSample);
        return NULL;
    }
    return outSample;
}

@interface BBProxyDelegate : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
- (instancetype)initWithTarget:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)target;
@end

@implementation BBProxyDelegate

- (instancetype)initWithTarget:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)target {
    _target = target;
    return self;
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
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = _target;
    if (!target) return;

    CMSampleBufferRef swapped = NULL;
    @try {
        swapped = BBCameraHookCreateSwappedSampleBuffer(sampleBuffer, BB_RING_PATH);
    } @catch (NSException *ex) {
        swapped = NULL;
    }

    if (swapped) {
        [target captureOutput:output didOutputSampleBuffer:swapped fromConnection:connection];
        CFRelease(swapped);
    } else {
        [target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

static const void *kBBProxyAssocKey = &kBBProxyAssocKey;
static IMP g_origSetSampleBufferDelegate = NULL;

static void bb_swizzled_setSampleBufferDelegate(
    AVCaptureVideoDataOutput *self,
    SEL _cmd,
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
    dispatch_queue_t queue)
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> forwardDelegate = delegate;
    BBProxyDelegate *newProxy = nil;
    if (delegate && object_getClass(delegate) != [BBProxyDelegate class]) {
        newProxy = [[BBProxyDelegate alloc] initWithTarget:delegate];
        forwardDelegate = newProxy;
    }

    ((void (*)(id, SEL, id, dispatch_queue_t))g_origSetSampleBufferDelegate)(self, _cmd, forwardDelegate, queue);

    if (newProxy) {
        objc_setAssociatedObject(self, kBBProxyAssocKey, newProxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!delegate) {
        objc_setAssociatedObject(self, kBBProxyAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        os_unfair_lock_lock(&g_reader_lock);
        bb_close_ring(&g_reader);
        os_unfair_lock_unlock(&g_reader_lock);
    }
}

__attribute__((constructor))
static void bb_camera_hook_init(void) {
    const char *prog = getprogname();
    if (!prog || strcmp(prog, "avconferenced") != 0) {
        return;
    }

    Class cls = objc_getClass("AVCaptureVideoDataOutput");
    if (!cls) return;

    SEL sel = @selector(setSampleBufferDelegate:queue:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    g_origSetSampleBufferDelegate = method_setImplementation(m, (IMP)bb_swizzled_setSampleBufferDelegate);
}
