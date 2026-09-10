using System.Collections.Generic;
using NAudio.CoreAudioApi;

namespace Bubilator88.Windows;

/// <summary>One selectable audio output device for the FDD Sound "Output Device" picker.</summary>
internal readonly record struct AudioDeviceInfo(string Id, string Name)
{
    /// Follow the system's default output device — mirrors macOS's
    /// AudioDeviceInfo.systemDefault (uid = "").
    public static AudioDeviceInfo SystemDefault => new("", "System Default");
}

/// <summary>
/// Enumerates WASAPI render (output) endpoints — the Windows analogue of
/// macOS's AudioDeviceList.swift (CoreAudio device enumeration). `Id` is the
/// same device-identifier string XAudio2's `CreateMasteringVoice(szDeviceId:)`
/// accepts, so a selection here can be handed straight to <see cref="FddSound"/>.
/// </summary>
internal static class AudioDeviceList
{
    /// Active output devices. First entry is always <see cref="AudioDeviceInfo.SystemDefault"/>.
    public static List<AudioDeviceInfo> OutputDevices()
    {
        var result = new List<AudioDeviceInfo> { AudioDeviceInfo.SystemDefault };
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                result.Add(new AudioDeviceInfo(device.ID, device.FriendlyName));
                device.Dispose();
            }
        }
        catch
        {
            // Device enumeration failed (no audio subsystem, permissions, etc.)
            // — fall back to System Default only, matching macOS's empty-array
            // fallback in AudioDeviceList.outputDevices().
        }
        return result;
    }
}
