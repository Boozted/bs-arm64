#pragma once
/* Minimal glib subset for Mono's zlib-helper.c */
#include <stdlib.h>
typedef int gint;
typedef unsigned char guchar;
typedef int gboolean;
#define TRUE 1
#define FALSE 0
#include <stdint.h>
typedef uint32_t guint32;
#define MONO_API __declspec(dllexport)
