//
//  AudioContext.h
//  System Audio
//
//  Created by Theodore Dubois on 5/9/21.
//

#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import "TPCircularBuffer.h"

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

@interface AudioContext : NSObject {
    @public
    unsigned ctxId;
    id config;

    bool running;
    mach_port_t clientPort;
    mach_port_t serverPort;
    int stream0Channels;
    double sampleRate;

    int shm_fd;
    void *buf;
    size_t bufSize;

    atomic_bool ring_active;
    UInt32 head_sample_time; // consumer only
    UInt32 tail_sample_time; // producer only
    TPCircularBuffer ring;
}
@end

void handle_context_config(unsigned ctx, id plist);
void handle_context_start(unsigned ctx, mach_port_t client, mach_port_t server);
void handle_context_stop(unsigned ctx);
void fetch_latest_audio(mach_port_t client_port, unsigned packet_id);

void enumerate_contexts(void (^cb)(AudioContext *ctx));

__END_DECLS
NS_ASSUME_NONNULL_END
