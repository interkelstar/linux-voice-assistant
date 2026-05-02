#!/bin/bash
set -e


# Add cookie file for pulseaudio to prevent errors
PULSE_COOKIE=${PULSE_COOKIE:-"/run/user/1000/pulse/cookie"}
if [[ "$PULSE_COOKIE" != "DISABLED" ]]; then
  if [ ! -f "$PULSE_COOKIE" ]; then
    echo "PulseAudio cookie file not found at $PULSE_COOKIE"
    PULSE_COOKIE="/app/configuration/tmp_pulse_cookie"
    echo "changed PULSE_COOKIE to $PULSE_COOKIE"
    if [ ! -f "$PULSE_COOKIE" ]; then
      echo "Creating PulseAudio cookie file at $PULSE_COOKIE"
      touch "$PULSE_COOKIE"
      chmod 600 "$PULSE_COOKIE"
    fi
  fi
fi


### Wait for PulseAudio
# Wait for PulseAudio to be available before starting the application
CP_MAX_RETRIES=30
CP_RETRY_DELAY=1
### while maybe besser?
echo "Checking PulseAudio service status..."
for i in $(seq 1 $CP_MAX_RETRIES); do
  # Check if PulseAudio is running
  if pactl info >/dev/null 2>&1; then
    echo "✅ PulseAudio is running"
    break
  fi

  if [ $i -eq $CP_MAX_RETRIES ]; then
      echo "❌ PulseAudio did not start after $CP_MAX_RETRIES seconds"
      exit 2
  fi

  echo "⏳ PulseAudio not running yet, retrying in $CP_RETRY_DELAY s..."
  sleep $CP_RETRY_DELAY
done


### Acoustic Echo Cancellation
# Convenience wrapper for the setup described in docs/enabling_aec.md.
# Loads the PulseAudio AEC module and sets AUDIO_INPUT_DEVICE automatically.
# See docs/enabling_aec.md for manual setup and PipeWire instructions.
if [ "${ENABLE_ECHO_CANCEL}" = "1" ]; then
  # AEC only cancels audio routed through its virtual sink. Naming both
  # source and sink explicitly lets us point LVA at them directly via
  # AUDIO_INPUT_DEVICE / AUDIO_OUTPUT_DEVICE, instead of relying on the
  # host's default sink (which other services may change).
  have_mic=n; have_sink=n
  if pactl list sources short 2>/dev/null | awk '{print $2}' | grep -qx aec_mic; then have_mic=y; fi
  if pactl list sinks   short 2>/dev/null | awk '{print $2}' | grep -qx aec_speaker; then have_sink=y; fi
  if [ "$have_mic" = "y" ] && [ "$have_sink" = "y" ]; then
    echo "✅ AEC source aec_mic and sink aec_speaker already present"
  else
    # Stale module-echo-cancel with different source/sink names would
    # leave aec_mic / aec_speaker missing; unload before reloading.
    stale=$(pactl list modules short 2>/dev/null | awk '/module-echo-cancel/ {print $1}')
    if [ -n "$stale" ]; then
      echo "↻ Unloading stale module-echo-cancel (id $stale)"
      pactl unload-module "$stale" || true
    fi
    if pactl load-module module-echo-cancel source_name=aec_mic sink_name=aec_speaker aec_method=webrtc; then
      echo "✅ Echo cancellation enabled (source=aec_mic, sink=aec_speaker)"
      have_mic=y; have_sink=y
    else
      echo "⚠️  Failed to load echo cancellation module (continuing without it)"
    fi
  fi
  # Only pin the app to aec_mic / aec_speaker when the module is actually
  # live; otherwise the app would crash on a missing source.
  if [ "$have_mic" = "y" ] && [ "$have_sink" = "y" ]; then
    # mpv's --audio-device selects an AO driver, so a bare PulseAudio sink
    # name fails to open; the "pulse/" prefix routes through the PA AO to
    # the named sink. The soundcard library on the input side takes the
    # plain PA source name, so aec_mic stays as-is.
    AUDIO_INPUT_DEVICE="${AUDIO_INPUT_DEVICE:-aec_mic}"
    AUDIO_OUTPUT_DEVICE="${AUDIO_OUTPUT_DEVICE:-pulse/aec_speaker}"
  else
    echo "⚠️  AEC unavailable; falling back to host default audio devices"
  fi
fi


### Handlers
# Handle parameters
EXTRA_ARGS=()

if [ "$ENABLE_DEBUG" = "1" ]; then
  EXTRA_ARGS+=( "--debug" )
fi

if [ -n "${CLIENT_NAME}" ]; then
  EXTRA_ARGS+=( "--name" "$CLIENT_NAME" )
fi

PREFERENCES_FILE=${PREFERENCES_FILE:-"/app/configuration/preferences.json"}
if [ -n "${PREFERENCES_FILE}" ]; then
  EXTRA_ARGS+=( "--preferences-file" "$PREFERENCES_FILE" )
fi

if [ -n "${NETWORK_INTERFACE}" ]; then
  EXTRA_ARGS+=( "--network-interface" "$NETWORK_INTERFACE" )
fi

# IP-ADDRESS
if [ -n "${HOST}" ]; then
  EXTRA_ARGS+=( "--host" "$HOST" )
fi

PORT=${PORT:-6053}
if [ -n "${PORT}" ]; then
  EXTRA_ARGS+=( "--port" "$PORT" )
fi

if [ -n "${AUDIO_INPUT_DEVICE}" ]; then
  EXTRA_ARGS+=( "--audio-input-device" "$AUDIO_INPUT_DEVICE" )
fi

if [ -n "${AUDIO_OUTPUT_DEVICE}" ]; then
  EXTRA_ARGS+=( "--audio-output-device" "$AUDIO_OUTPUT_DEVICE" )
fi

if [ "$ENABLE_THINKING_SOUND" = "1" ]; then
  EXTRA_ARGS+=( "--enable-thinking-sound" )
fi

if [ -n "${WAKE_WORD_DIR}" ]; then
  EXTRA_ARGS+=( "--wake-word-dir" "$WAKE_WORD_DIR" )
fi

if [ -n "${WAKE_MODEL}" ]; then
  EXTRA_ARGS+=( "--wake-model" "$WAKE_MODEL" )
fi

if [ -n "${STOP_MODEL}" ]; then
  EXTRA_ARGS+=( "--stop-model" "$STOP_MODEL" )
fi

if [ -n "${REFACTORY_SECONDS}" ]; then
  EXTRA_ARGS+=( "--refractory-seconds" "$REFACTORY_SECONDS" )
fi

if [ -n "${WAKEUP_SOUND}" ]; then
  EXTRA_ARGS+=( "--wakeup-sound" "$WAKEUP_SOUND" )
fi

if [ -n "${TIMER_FINISHED_SOUND}" ]; then
  EXTRA_ARGS+=( "--timer-finished-sound" "$TIMER_FINISHED_SOUND" )
fi

if [ -n "${PROCESSING_SOUND}" ]; then
  EXTRA_ARGS+=( "--processing-sound" "$PROCESSING_SOUND" )
fi

if [ -n "${MUTE_SOUND}" ]; then
  EXTRA_ARGS+=( "--mute-sound" "$MUTE_SOUND" )
fi

if [ -n "${UNMUTE_SOUND}" ]; then
  EXTRA_ARGS+=( "--unmute-sound" "$UNMUTE_SOUND" )
fi


### Start application
if [ "$LIST_DEVICES" = "1" ]; then
  echo "list input devices"
  ./script/run "$@" "${EXTRA_ARGS[@]}" --list-input-devices
  echo "list output devices"
  ./script/run "$@" "${EXTRA_ARGS[@]}" --list-output-devices
  echo "wait 20s and then starting the application"
  sleep 20
fi

echo "starting application"
exec ./script/run "$@" "${EXTRA_ARGS[@]}"
