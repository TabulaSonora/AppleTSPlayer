//
//  Tabula_Sonora_AUParameterAddresses.h
//  Tabula Sonora AU
//

#pragma once

#include <AudioToolbox/AUParameters.h>

/// The plugin's parameters, which are the engine's settings and nothing else.
///
/// Only `gain` is a parameter in the sense a host means it -- a number that may be automated and
/// changed inside a render block. Every other address here rebuilds the tone generator when it
/// moves, which is milliseconds of work and the loss of every sounding voice, so the render block
/// ignores them and they are applied from the control path instead.
///
/// They are parameters at all because that is how a host saves and restores them: the default
/// `fullState` carries the parameter tree, so a session that reopens on an SC-55 with the reverb off
/// reopens that way without a line of state-encoding code.
typedef NS_ENUM(AUParameterAddress, Tabula_Sonora_AUParameterAddress) {
    gain = 0,
    toneMap,
    polyphony,
    ports,
    reverb,
    chorus,
    delayEffect,
    insertionEffects,
    extendedResampler,
};
