//
//  SystemAudio.h
//  System Audio
//
//  Created by tbodt on 6/6/21.
//

OSStatus initialize_hooks(void *coreaudio_pointer);
bool is_input_running(void);
extern Float64 mach_ticks_per_second;
