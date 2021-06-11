//
//  AudioContext.m
//  System Audio
//
//  Created by Theodore Dubois on 5/9/21.
//

#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <sys/stat.h>
#import "SystemAudio.h"
#import "AudioContext.h"

static NSLock *contextsLock;
static NSMutableDictionary<NSNumber *, AudioContext *> *contextsByID;
static NSMutableDictionary<NSNumber *, AudioContext *> *contextsByPort;
static NSMutableDictionary<NSNumber *, id> *acom;

@implementation AudioContext
- (int)openBuffer {
    [self closeBuffer];
    
    shm_fd = shm_open([NSString stringWithFormat:@"AudioIO%X", ctxId].UTF8String, O_RDONLY);
    if (shm_fd < 0)
        return shm_fd;
    struct stat statbuf = {};
    if (fstat(shm_fd, &statbuf) < 0)
        return -1;
    bufSize = statbuf.st_size;
    buf = mmap(NULL, bufSize, PROT_READ, MAP_SHARED, shm_fd, 0);
    if (buf == MAP_FAILED) {
        buf = NULL;
        return -1;
    }
    if (stream0Channels <= 0) {
        NSLog(@"systemaudio: pakala a, linja %d la mute kalama lon nasin nanpa wan li ala %d tan %@", ctxId, stream0Channels, config);
        errno = EINVAL;
        return -1; // otherwise would trip an assert in TPCircularBufferInit
    }
    TPCircularBufferCleanup(&ring);
    // a page fits approximately 1k samples which is on the order of 20ms. multiply by the number of channels, then multiply by 8 just to be sure.
    if (!TPCircularBufferInit(&ring, PAGE_SIZE*stream0Channels*8)) {
        errno = ENOMEM;
        return -1;
    }
    return 0;
}
- (void)closeBuffer {
    if (shm_fd >= 0) {
        close(shm_fd);
        shm_fd = 0;
    }
    if (buf != NULL) {
        munmap(buf, bufSize);
        buf = NULL;
    }
}
+ (void)initialize {
    contextsLock = [NSLock new];
    contextsByID = [NSMutableDictionary new];
    contextsByPort = [NSMutableDictionary new];
    acom = [NSMutableDictionary new];
}
+ (instancetype)contextById:(unsigned)ctxId {
    AudioContext *ctx = [contextsByID objectForKey:@(ctxId)];
    if (ctx == nil) {
        ctx = [AudioContext new];
        ctx->ctxId = ctxId;
        [contextsByID setObject:ctx forKey:@(ctxId)];
    }
    return ctx;
}
- (void)dealloc {
    [self closeBuffer];
}
@end

void handle_aggregate_composition(unsigned dev, id plist) {
    [contextsLock lock];
    acom[plist] = @(dev);
    [contextsLock unlock];
}

void handle_context_config(unsigned ctxId, id plist) {
    [contextsLock lock];
    AudioContext *ctx = [AudioContext contextById:ctxId];
    ctx->config = plist;
    ctx->stream0Channels = [plist[@"grid-out"][0][@"channels"] intValue];
    [contextsLock unlock];
}

void handle_context_start(unsigned ctxId, mach_port_t client, mach_port_t server) {
    [contextsLock lock];
    AudioContext *ctx = [AudioContext contextById:ctxId];
    if (ctx->running) {
        NSLog(@"systemaudio: ike a! sona mi la linja %d li open lon tenpo pini! mi ken ala open sin!", ctx->ctxId);
    } else {
        ctx->running = true;
        ctx->clientPort = client;
        ctx->serverPort = server;
        if ([ctx openBuffer] < 0) {
            NSLog(@"systemaudio: mi ken ala lukin e lipu kalama, tan %s", strerror(errno));
            [contextsLock unlock];
            return;
        }
        contextsByPort[@(ctx->clientPort)] = ctx;
        contextsByPort[@(ctx->serverPort)] = ctx;
        NSLog(@"systemaudio: linja li open! id=%d, client_port=%d, server_port=%d", ctxId, client, server);
    }
    [contextsLock unlock];
}

void handle_context_stop(unsigned ctxId) {
    [contextsLock lock];
    AudioContext *ctx = [AudioContext contextById:ctxId];
    if (!ctx->running) {
        NSLog(@"systemaudio: ike a! sona mi la linja %d li pini lon tenpo pini! mi ken ala pini sin!", ctxId);
    } else {
        ctx->running = false;
        ctx->sampleRate = 0;
        ctx->ring_active = false; // ugh this is probably racy af but I am tired and tsan doesn't work in coreaudio so no one has to know
        AudioConverterDispose(ctx->converter);
        ctx->converter = NULL;
        [contextsByPort removeObjectForKey:@(ctx->clientPort)];
        [contextsByPort removeObjectForKey:@(ctx->serverPort)];
        NSLog(@"systemaudio: linja li pini! id=%d", ctxId);
    }
    [contextsLock unlock];
}

struct buffer_header {
    double ticksInBuffer;
    double not_sure; // seems to reciprocal of ticksInBuffer
    double rateScalar;
    int samples;
    AudioTimeStamp unsure;
    AudioTimeStamp now;
    AudioTimeStamp inputTime;
    AudioTimeStamp outputTime;
};
// second page: two arrays, both formatted as (32 bit element count) (each element as 32 bit integer). first is an array of output buffers, second is an array of input buffers. the element in the array is the size of the buffer. buffers are packed starting at the end of both arrays. but the starts are rounded up so each buffer starts at a page.

NSString *toki_e_tenpo(AudioTimeStamp tenpo) {
    return [NSString stringWithFormat:@"{%f %f}", tenpo.mSampleTime, tenpo.mHostTime / 1000000000.];
}
bool floats_equal(double a, double b) {
    double diff = fabs(a - b);
    double ulp = fabs(nextafter(a, b) - a);
    return diff < 4*ulp;
}
void fetch_latest_audio(mach_port_t port, unsigned packet_id) {
    [contextsLock lock];
    AudioContext *ctx = [contextsByPort objectForKey:@(port)];
    [contextsLock unlock];
    if (ctx == nil) {
        // ike ni li lili. mi ken ala sona pona e ni: mi lon ni tan kama kalama anu seme
//        NSLog(@"systemaudio: ike a! sona mi la linja pi ijo %d li lon ala! mi ken ala alasa e kalama!", port);
        return;
    }
//    NSLog(@"systemaudio: linja %d la mi wile jo e kalama lon tenpo nanpa %d a!", ctx->ctxId, packet_id);
    
    struct buffer_header *header = ctx->buf;
    if (header->ticksInBuffer != 1 / header->not_sure) {
        NSLog(@"systemaudio: ijo li nasa! %.10f %.10f", header->ticksInBuffer, 1/header->not_sure);
    }
//    NSLog(@"systemaudio: linja %d la ijo #1 = %.10f, ijo #2 = %.10f, ijo #3 = %.10f, mute = %d, tenpo #1 = %@, tenpo lon = %@, tenpo pi ijo lete = %@, tenpo pi ijo seli = %@, tenpo lon lon = %f", ctx->ctxId, header->ticksInBuffer, header->not_sure, header->rateScalar, header->samples, toki_e_tenpo(header->unsure), toki_e_tenpo(header->now), toki_e_tenpo(header->inputTime), toki_e_tenpo(header->outputTime), AudioGetCurrentHostTime() / 1000000000.);

    double sampleRate = 1000000000 / (header->ticksInBuffer / header->rateScalar);
    if (ctx->sampleRate == 0)
        ctx->sampleRate = sampleRate;
    else if (fabs(ctx->sampleRate - sampleRate) > 0.1) {
        NSLog(@"systemaudio: linja %d la mute tenpo li ante tan %.30f tawa %.30f la mi ala", ctx->ctxId, ctx->sampleRate, sampleRate);
        return;
    }
    uint32_t *outputArr = (uint32_t *) (ctx->buf + PAGE_SIZE) + 1;
    uint32_t *inputArr = outputArr + outputArr[-1] + 1;
    uintptr_t bufferAddr = ((uintptr_t) (inputArr + inputArr[-1]) + PAGE_SIZE - 1) & ~(PAGE_SIZE-1);
    uint32_t bufferSize = outputArr[0];
    Float32 *bufFloats = (void *) bufferAddr;
    Float32 avg = 0;
    for (int i = 0; i < bufferSize / sizeof(Float32); i++) {
        avg += bufFloats[i] / (bufferSize/sizeof(Float32));
    }
//    NSLog(@"systemaudio: linja %d la mute tenpo li %f, mute linja li %d, mute nanpa li %d, ma nanpa li %p, suli ma li %#x suli kalama li %f", ctx->ctxId, sampleRate, ctx->stream0Channels, header->samples, (void *) bufferAddr, bufferSize, avg);
    
    bool input_running = is_input_running();
    bool ring_active = ctx->ring_active;
    if (input_running && !ring_active) {
        TPCircularBufferClear(&ctx->ring);
        ctx->head_sample_time = ctx->tail_sample_time = header->outputTime.mSampleTime;
        ctx->ring_active = ring_active = true;
    } else if (!input_running && ring_active) {
        ctx->ring_active = ring_active = false;
    }
    if (!ring_active)
        return;

    uint32_t bytesPerFrame = ctx->stream0Channels * sizeof(Float32);
    uint32_t dataSize = header->samples * bytesPerFrame;
    uint32_t extraZeros = (header->outputTime.mSampleTime - ctx->head_sample_time) * bytesPerFrame;
    uint32_t availableBytes;
    void *head = TPCircularBufferHead(&ctx->ring, &availableBytes);
    if (availableBytes < extraZeros + dataSize) {
        NSLog(@"systemaudio: linja %d la mi ken ala pana e ijo ala %u e ijo sin %u, ijo %u taso li ken sin", ctx->ctxId, extraZeros, dataSize, availableBytes);
        if (availableBytes < extraZeros)
            extraZeros = availableBytes;
        dataSize = availableBytes - extraZeros;
    }
//    NSLog(@"systemaudio: linja %d mi lukin pana e ijo ala %u e ijo sin %u", ctx->ctxId, extraZeros, dataSize);
    dataSize -= dataSize % bytesPerFrame;
    extraZeros -= extraZeros % bytesPerFrame;
    memset(head, 0, extraZeros);
    memcpy(head + extraZeros, (void *) bufferAddr, dataSize);
    TPCircularBufferProduce(&ctx->ring, extraZeros + dataSize);
    ctx->head_sample_time += (extraZeros + dataSize) / bytesPerFrame;
}

void enumerate_contexts(void (^cb)(AudioContext *ctx)) {
    [contextsLock lock];
    NSArray *ctxs = [contextsByID allValues];
    [contextsLock unlock];
    for (AudioContext *ctx in ctxs) {
        if (!ctx->ring_active)
            continue;
        cb(ctx);
    }
}
