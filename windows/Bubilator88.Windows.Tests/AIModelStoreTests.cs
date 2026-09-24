using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Bubilator88.Windows.Tests;

public sealed class AIModelStoreTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task DownloadRejectsInvalidPayloadWithoutInstalling(bool wrongSize, bool wrongHash)
    {
        byte[] bytes = "verified model"u8.ToArray();
        var model = Model(bytes, wrongSize, wrongHash);
        string root = NewRoot();
        try
        {
            using var client = Client(bytes);
            var store = new AIModelStore(root);
            if (wrongSize || wrongHash)
                await Assert.ThrowsAsync<InvalidDataException>(() =>
                    store.DownloadAsync(model, client, null, CancellationToken.None));
            else
            {
                await store.DownloadAsync(model, client, null, CancellationToken.None);
                Assert.Equal(bytes, File.ReadAllBytes(store.InstalledPath(model)!));
                store.Remove(model);
            }
            Assert.False(store.IsInstalled(model));
            Assert.Empty(Directory.GetFileSystemEntries(root));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public async Task CancellationLeavesNoInstallOrStagingDirectory()
    {
        byte[] bytes = "some model bytes"u8.ToArray();
        string root = NewRoot();
        using var cts = new CancellationTokenSource();
        using var client = Client(bytes);
        var store = new AIModelStore(root);
        try
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                store.DownloadAsync(Model(bytes), client,
                    new CancelProgress(cts), cts.Token));
            Assert.Empty(Directory.GetFileSystemEntries(root));
        }
        finally { Directory.Delete(root, true); }
    }

    private static DownloadableAIModel Model(byte[] bytes, bool wrongSize = false, bool wrongHash = false)
        => new("test", new Uri("https://example.invalid/test.onnx"),
            wrongHash ? new string('0', 64) : Convert.ToHexString(SHA256.HashData(bytes)),
            bytes.Length + (wrongSize ? 1 : 0));

    private static string NewRoot()
    {
        string path = Path.Combine(Path.GetTempPath(), "b88-model-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static HttpClient Client(byte[] bytes) => new(new PayloadHandler(bytes));

    private sealed class PayloadHandler(byte[] bytes) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            { Content = new ByteArrayContent(bytes) });
    }

    private sealed class CancelProgress(CancellationTokenSource source) : IProgress<long>
    {
        public void Report(long value) => source.Cancel();
    }
}
