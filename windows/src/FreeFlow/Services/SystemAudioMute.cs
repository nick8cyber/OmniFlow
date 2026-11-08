using NAudio.CoreAudioApi;

namespace FreeFlow.Services;

/// <summary>
/// Mutes the default render endpoint for the duration of a dictation session
/// (macOS "Mute audio when dictation starts" parity, user opt-in). The previous
/// mute state is captured once and restored at session end; every failure is
/// best-effort — audio policy must never break dictation.
/// </summary>
public static class SystemAudioMute
{
    private static readonly object Gate = new();
    private static bool? _previousMute;

    public static void MuteForDictation()
    {
        lock (Gate)
        {
            if (_previousMute.HasValue) return; // a session is already muting
            try
            {
                var device = new MMDeviceEnumerator()
                    .GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                _previousMute = device.AudioEndpointVolume.Mute;
                if (!_previousMute.Value) device.AudioEndpointVolume.Mute = true;
            }
            catch (Exception)
            {
                _previousMute = null; // no endpoint / blocked: nothing to restore
            }
        }
    }

    public static void RestoreAfterDictation()
    {
        lock (Gate)
        {
            if (!_previousMute.HasValue) return;
            var wasMuted = _previousMute.Value;
            _previousMute = null;
            try
            {
                var device = new MMDeviceEnumerator()
                    .GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                device.AudioEndpointVolume.Mute = wasMuted;
            }
            catch (Exception)
            {
                // Endpoint gone (device switch mid-session): nothing restoreable.
            }
        }
    }
}
