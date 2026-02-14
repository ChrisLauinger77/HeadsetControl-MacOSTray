#ifndef HEADSETCONTROLCLIB_H
#define HEADSETCONTROLCLIB_H

#if __has_include(<headsetcontrol/headsetcontrol_c.h>)
#include <headsetcontrol/headsetcontrol_c.h>
#elif __has_include(<headsetcontrol_c.h>)
#include <headsetcontrol_c.h>
#else
#error "headsetcontrol_c.h not found. Install libheadsetcontrol headers."
#endif

#endif
