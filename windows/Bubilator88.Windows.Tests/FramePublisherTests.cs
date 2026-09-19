using Bubilator88.Windows;
using Xunit;

namespace Bubilator88.Windows.Tests;

public class FramePublisherTests
{
    private const int Bytes = 4;

    private static byte[] Frame(byte value) => new[] { value, value, value, value };

    [Fact]
    public void AcquireLatest_NothingPublished_ReturnsNull()
        => Assert.Null(new FramePublisher(Bytes).AcquireLatest());

    [Fact]
    public void AcquireLatest_ReturnsPublishedFrameOnce()
    {
        var pub = new FramePublisher(Bytes);
        pub.Publish(Frame(7), is400Line: true);

        FrameSlot? slot = pub.AcquireLatest();
        Assert.NotNull(slot);
        Assert.Equal(Frame(7), slot!.Pixels);
        Assert.True(slot.Is400Line);
        Assert.Null(pub.AcquireLatest());
    }

    [Fact]
    public void Publish_UnconsumedFrameIsReplacedByNewest()
    {
        var pub = new FramePublisher(Bytes);
        for (byte i = 1; i <= 10; i++) pub.Publish(Frame(i), is400Line: false);

        Assert.Equal(Frame(10), pub.AcquireLatest()!.Pixels);
    }

    [Fact]
    public void Publish_NeverWritesTheSlotTheConsumerHolds()
    {
        var pub = new FramePublisher(Bytes);
        pub.Publish(Frame(1), is400Line: false);
        FrameSlot held = pub.AcquireLatest()!;

        // The producer keeps running while the consumer holds its slot.
        for (byte i = 2; i <= 20; i++) pub.Publish(Frame(i), is400Line: true);

        Assert.Equal(Frame(1), held.Pixels);
        Assert.False(held.Is400Line);
        Assert.Equal(Frame(20), pub.AcquireLatest()!.Pixels);
    }

    [Fact]
    public void PublishedCount_CountsOnlyCountedFrames()
    {
        var pub = new FramePublisher(Bytes);
        pub.Publish(Frame(1), is400Line: false);
        pub.Publish(Frame(2), is400Line: false, counted: false);
        pub.Publish(Frame(3), is400Line: false);

        Assert.Equal(2, pub.PublishedCount);
    }
}
