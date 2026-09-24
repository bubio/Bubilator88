using System;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Bubilator88.Windows;

internal sealed record DownloadableAIModel(string Name, Uri Url, string Sha256, long ByteCount)
{
    public string InstallDirectoryName => $"{Name}-{Sha256[..12]}";
}

/// <summary>Installs only models identified by the built-in manifest.</summary>
internal sealed class AIModelStore
{
    internal static readonly DownloadableAIModel Quality = new(
        "RealESRGAN_x2",
        new Uri("https://github.com/bubio/Bubilator88/releases/download/models-v1/RealESRGAN_x2.onnx"),
        "74786f9a2680d8c887f51c74131b2233d0f8910c5e5307e1beee71f69a88a4f0",
        67_072_862);

    internal static AIModelStore Shared { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "DownloadedModels"));

    private readonly string _root;

    internal AIModelStore(string root) => _root = root;

    internal string? InstalledPath(DownloadableAIModel model)
    {
        string path = Path.Combine(_root, model.InstallDirectoryName, model.Name + ".onnx");
        return File.Exists(path) ? path : null;
    }

    internal bool IsInstalled(DownloadableAIModel model) => InstalledPath(model) is not null;

    internal async Task DownloadAsync(DownloadableAIModel model, HttpClient client,
        IProgress<long>? progress, CancellationToken cancellationToken)
    {
        if (IsInstalled(model)) return;
        Directory.CreateDirectory(_root);
        string staging = Path.Combine(_root, ".staging-" + Guid.NewGuid().ToString("N"));
        string destination = Path.Combine(_root, model.InstallDirectoryName);
        Directory.CreateDirectory(staging);
        try
        {
            using var response = await client.GetAsync(model.Url,
                HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            response.EnsureSuccessStatusCode();
            string path = Path.Combine(staging, model.Name + ".onnx");
            await using var input = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 128 * 1024, useAsync: true))
            {
                byte[] buffer = new byte[128 * 1024];
                long received = 0;
                int count;
                while ((count = await input.ReadAsync(buffer, cancellationToken)) != 0)
                {
                    received += count;
                    if (received > model.ByteCount)
                        throw new InvalidDataException("The downloaded model is larger than expected.");
                    await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken);
                    progress?.Report(received);
                }
                if (received != model.ByteCount)
                    throw new InvalidDataException($"The downloaded model has the wrong size ({received} bytes).");
            }
            cancellationToken.ThrowIfCancellationRequested();
            await using (var verified = File.OpenRead(path))
            {
                string hash = Convert.ToHexString(await SHA256.HashDataAsync(verified, cancellationToken));
                if (!hash.Equals(model.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The downloaded model failed its SHA-256 check.");
            }
            cancellationToken.ThrowIfCancellationRequested();
            // The staging directory and final directory share a volume. A failed
            // download never leaves a partially installed model visible.
            if (Directory.Exists(destination))
                throw new IOException("The model installation directory already exists without a valid model.");
            Directory.Move(staging, destination);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    internal void Remove(DownloadableAIModel model)
    {
        string path = Path.Combine(_root, model.InstallDirectoryName);
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
    }
}
