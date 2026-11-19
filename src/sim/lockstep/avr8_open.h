// Includes Uzem's avr8.h with its private members opened for the lockstep test bench (the system
// headers it pulls in are included first, so only avr8's own declarations are affected).
#pragma once
#include <vector>
#include <queue>
#include <string>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <windows.h>
#include <winioctl.h>
#include <SDL2/SDL.h>
#include "SDEmulator.h"
#define private public
#include "avr8.h"
#undef private
