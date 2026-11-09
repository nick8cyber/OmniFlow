using System.IO;
using System.Media;
using Microsoft.Win32;
using NAudio.Wave;

namespace OmniFlow.Services;

/// <summary>
/// Plays the system alert sounds through a volume-controllable path. The
/// SystemSounds shortcuts cannot be volume-adjusted, so the WAV file the current
/// sound scheme maps the alias to (HKCU AppEvents\Schemes) is played through
/// WaveOutEvent with the user's volume. A missing scheme entry or any failure
/// falls back to SystemSounds — the exact previous behavior.
/// </summary>
public static class AlertPlayer
{
    public static void Play(string systemAlias, float volume)
    {
        try
        {
            var wavPath = SchemeWavPath(systemAlias);
            if (wavPath == null || !File.Exists(wavPath))
            {
                SystemSoundForAlias(systemAlias).Play();
                return;
            }
            var reader = new AudioFileReader(wavPath);
            var output = new WaveOutEvent { Volume = Math.Clamp(volume, 0f, 1f) };
            output.Init(reader);
            output.PlaybackStopped += (_, _) =>
            {
                output.Dispose();
                reader.Dispose();
            };
            output.Play();
        }
        catch (Exception)
        {
            try { SystemSoundForAlias(systemAlias).Play(); } catch { /* best-effort */ }
        }
    }

    private static string? SchemeWavPath(string systemAlias)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                $@"AppEvents\Schemes\Apps\.Default\{systemAlias}\.current");
            return key?.GetValue(null) as string;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static SystemSound SystemSoundForAlias(string alias) => alias switch
    {
        "SystemHand" => SystemSounds.Hand,
        "SystemAsterisk" => SystemSounds.Asterisk,
        "SystemExclamation" => SystemSounds.Exclamation,
        _ => SystemSounds.Beep,
    };
}
