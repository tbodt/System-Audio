//
//  Hooks.m
//  System Audio
//
//  Created by Theodore Dubois on 5/23/21.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioServerPlugIn.h>
#import <mach/message.h>
#import <mach-o/getsect.h>
#import <bsm/libbsm.h>
#import <dlfcn.h>
#import "AudioContext.h"

#define FourCCToCString(c) (char[]){ (char)((c)>>24), (char)((c)>>16), (char)((c)>>8), (char)(c), 0 }

static NSString *hexdump(void *data, size_t size) {
    uint8_t *cdata = data;
    NSMutableString *str = [NSMutableString new];
    for (size_t i = 0; i < size; i++) {
        if (i != 0 && i % 4 == 0)
            [str appendString:@" "];
        [str appendFormat:@"%02x", cdata[i]];
    }
    return str;
}

// all MIG requests and responses start with 24 bytes for a mach header, will be ignoring that

typedef mach_msg_return_t (*mig_callback_t)(mach_msg_header_t *message, mach_msg_header_t *reply);
static __thread mig_callback_t mig_cb;

static pid_t pid_from_mach_trailer(mach_msg_header_t *msg) {
    mach_msg_audit_trailer_t *trailer = (void *) ((char *) msg + msg->msgh_size);
    return audit_token_to_pid(trailer->msgh_audit);
}
void log_chop(NSString *prefix, NSString *str) {
    NSUInteger i = 0;
    while (i < str.length) {
        NSUInteger len = 1000;
        if (i + len >= str.length)
            len = str.length - i;
        NSLog(@"systemaudio %@ sona li %@", prefix, [str substringWithRange:NSMakeRange(i, len)]);
        i += len;
    }
}

static const char *stringify_message(int msgid) {
    static const char *msg_names[] = {
        [3] = "System_CreateIOContext",
        [10] = "IOContext_SetClientControlPort",
        [11] = "IOContext_Start",
        [12] = "IOContext_Stop",
        [34] = "Object_SetPropertyData_DPlist",
        [53] = "System_OpenWithBundleIDAndLinkage",
        [58] = "IOContext_Start_With_WorkInterval",
    };

    const char *msg_name = NULL;
    if (msgid - 1010000 < sizeof(msg_names)/sizeof(msg_names[0]))
        msg_name = msg_names[msgid - 1010000];
    if (msg_name == NULL)
        msg_name = "(seme)";
    return msg_name;
}

static mach_msg_return_t hook_mig_callback(mach_msg_header_t *msg, mach_msg_header_t *reply) {
    id plist = nil;
    switch (msg->msgh_id) {
        case 1010003: // System_CreateIOContext
        case 1010034: { // Object_SetPropertyData_DPlist
            struct mach_message_with_ool {
                mach_msg_base_t base;
                mach_msg_ool_descriptor_t desc;
            };
            struct mach_message_with_ool *req = (void *) msg;
            const char *msg_name = stringify_message(req->base.header.msgh_id);
            if (!req->desc.address) {
                NSLog(@"systemaudio %s a a mi kala", msg_name);
                break;
            }
            NSData *data = [NSData dataWithBytes:req->desc.address length:req->desc.size];
            NSError *err = nil;
            plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:&err];
        } break;
    }

    mach_msg_return_t res = mig_cb(msg, reply);

    switch (msg->msgh_id) {
        case 1010003: {
            // example request:
            // 0x18: 01000000 00000000 00000000 01010001 00000000 00000000 01000000 5a020000
            // example response:
            struct mig_response_System_CreateIOContext {
                mach_msg_header_t header;
                // 0x18: 00000000 01000000 ndr bullshit
                NDR_record_t ndr;
                // 0x20: 00000000 some kind of status code
                unsigned int status;
                // 0x24: 67000000 context id
                unsigned int ctx_id;
            };

            struct mig_response_System_CreateIOContext *resp = (void *) reply;
            if (resp->status != 0) {
                NSLog(@"systemaudio: pali linja li ike=%d, la mi ala", resp->status);
                break;
            }
            NSLog(@"systemaudio: linja sin li kama! id=%d, pid=%d, sona=%@", resp->ctx_id, pid_from_mach_trailer(msg), plist);
            handle_context_config(resp->ctx_id, plist);
        } break;
        case 1010034: {
            // example request:
            // 0x2c:   0f010000
            struct mig_request_System_SetPropertyData_DPlist {
                mach_msg_header_t header;
                // 0x18: 00000000
                mach_msg_body_t body;
                // 0x19: 00000000 00000000 01010001 00000000
                mach_msg_ool_descriptor_t desc;
                // 0x2c: 00000000 01000000
                unsigned int unsure[2];
                // 0x34: f2000000
                unsigned int ctx_id;
                // 0x38: 70757267 626f6c67 00000000
                AudioObjectPropertyAddress prop;
                unsigned int also_unsure;
            };
            struct mig_request_System_SetPropertyData_DPlist *req = (void *) msg;
            if (req->prop.mSelector == kAudioAggregateDevicePropertyComposition)
                handle_context_config(req->ctx_id, plist);
        } break;
        case 1010011:
            // IOContext_Start
            // example req: 12110080 34000000 63ce0300 13040300 00000000 5b690f00 01000000 5fcc0300 00000000 00001100 00000000 01000000 67010000
            // example req: 12000080 28000000 63ce0300 00000000 00000000 bf690f00 01000000 4fd00300 00000000 00001400
        case 1010058: {
            // IOContext_Start_With_WorkInterval, coincidentally uses the same req/res structures, but with a bit extra on the resp:
            // 0x28: 17ea0100 work interval port!
            // 0x2c: 00000000 00001100 idk
          struct mig_request_IOContext_Start {
                mach_msg_header_t header;
                // 0x18: 01000000 idk
                unsigned int idk1;
                // 0x1c: 132f0100 mach port
                mach_port_t port;
                // 0x20: 00000000 00001100 00000000 01000000 idk
                unsigned int idk2[4];
                // 0x30: 6f010000 context id
                unsigned int ctx_id;
            };
            struct mig_response_IOContext_Start {
                mach_msg_header_t header;
                // 0x18: 02000000 idk
                unsigned int idk1;
                // 0x1c: 171f0200 mach port
                mach_port_t port;
                // 0x20: 00000000 status
                unsigned int status;
                // 0x24: 00001400 idk
            };

            struct mig_request_IOContext_Start *req = (void *) msg;
            struct mig_response_IOContext_Start *resp = (void *) reply;
            if (resp->status != 0) {
                NSLog(@"systemaudio: kama open linja li ike=%d, la mi ala", resp->status);
                break;
            }
            NSLog(@"systemaudio: linja li kama open lon ilo nanpa %d", pid_from_mach_trailer(msg));
            handle_context_start(req->ctx_id, req->port, resp->port);
        } break;
        case 1010012: { // IOContext_Stop
            struct mig_request_IOContext_Stop {
                mach_msg_header_t header;
                // 0x18: 00000000 01000000 idk
                NDR_record_t ndr;
                // 0x20: 71010000 context id
                unsigned int ctx_id;
            };
            // 0x18: 00000000 01000000 00000000 idk
            struct mig_response_IOContext_Stop {
                mach_msg_header_t header;
                // 0x18: 00000000 01000000 idk
                NDR_record_t ndr;
                // 0x20: 00000000 status
                unsigned int status;
            };
            struct mig_request_IOContext_Stop *req = (void *) msg;
            struct mig_response_IOContext_Stop *resp = (void *) reply;
            if (resp->status != 0) {
                NSLog(@"systemaudio: kama pini linja li ike=%d, la mi ala", resp->status);
                break;
            }
            handle_context_stop(req->ctx_id);
        } break;
    }
    return res;
}

extern mach_msg_return_t dispatch_mig_server(dispatch_source_t ds, size_t maxmsgsz, mig_callback_t callback);
static mach_msg_return_t hook_dispatch_mig_server(dispatch_source_t ds, size_t maxmsgsz, mig_callback_t callback) {
    if (mig_cb != NULL) {
        NSLog(@"systemaudio: hook_dispatch_mig_server li kama sin lon tenpo sama, la mi pali ala");
        return dispatch_mig_server(ds, maxmsgsz, callback);
    }
    mig_cb = callback;
    callback = hook_mig_callback;
    mach_msg_return_t res = dispatch_mig_server(ds, maxmsgsz, callback);
    mig_cb = NULL;
    return res;
}

static mach_msg_return_t hook_mach_msg(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send_size, mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout, mach_port_name_t notify) {
    if (option & MACH_RCV_MSG) {
        fetch_latest_audio(rcv_name, msg->msgh_id);
    }
    mach_msg_return_t res = mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    return res;
}

// interpose without dyld's help
static int interpose(void *module, void *hook, void *func) {
    size_t relro_size;
    void *relro_seg = getsegmentdata(module, "__AUTH_CONST", &relro_size);
    if (relro_seg == NULL)
        relro_seg = getsegmentdata(module, "__DATA_CONST", &relro_size);
    if (relro_seg == NULL)
        relro_seg = getsegmentdata(module, "__DATA", &relro_size);
    if (relro_seg == NULL) {
        NSLog(@"SystemAudio: failed to get relro segment");
        return 1;
    }
    void **data_to_search = relro_seg;
    size_t search_size = relro_size / sizeof(void *);
    for (size_t i = 0; i < search_size; i++) {
        if (data_to_search[i] == func) {
            data_to_search[i] = hook;
            return 0;
        }
    }
    NSLog(@"SystemAudio: failed to find pointer in got");
    return 1;
}

OSStatus initialize_hooks(void *coreaudio_pointer) {
    // first get the mach header for whatever is implementing the host interface, which we hope is the right one
    struct dl_info info = {};
    dladdr(coreaudio_pointer, &info);
    void *coreaudio_mach_header = info.dli_fbase;
    if (coreaudio_mach_header == NULL) {
        NSLog(@"SystemAudio: failed to alasa e ilo pi tawa kalama");
        return kAudioHardwareUnspecifiedError;
    }
    NSLog(@"SystemAudio: mi alasa e ilo. nimi ona li %s", info.dli_fname);
    if (interpose(coreaudio_mach_header, hook_mach_msg, mach_msg) != 0)
        return kAudioHardwareUnspecifiedError;
    if (interpose(coreaudio_mach_header, hook_dispatch_mig_server, dispatch_mig_server) != 0)
        return kAudioHardwareUnspecifiedError;
    return kAudioHardwareNoError;
}
