using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using WinRT;
using static Vortice.Direct3D11.D3D11;

namespace Bubilator88.Windows;

/// <summary>
/// Direct3D 11 presenter for the 640×400 emulator frame, composited onto a
/// WinUI 3 <see cref="SwapChainPanel"/>. A dynamic R8G8B8A8 texture is updated
/// each frame from the core's RGBA buffer and drawn with a point (nearest)
/// sampler onto a fullscreen triangle — the D3D analogue of the macOS
/// Display.metal passthrough path.
/// </summary>
internal sealed unsafe class D3DScreen : IDisposable
{
    [ComImport, Guid("63aad0b8-7c24-40ff-85a8-640d944cc325"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISwapChainPanelNative
    {
        [PreserveSig] int SetSwapChain(IntPtr swapChain);
    }

    private const string Hlsl = """
        Texture2D    Tex : register(t0);
        SamplerState Smp : register(s0);
        struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
        VSOut VSMain(uint vid : SV_VertexID) {
            VSOut o;
            float2 uv = float2((vid << 1) & 2, vid & 2);
            o.uv  = uv;
            o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
            return o;
        }
        float4 PSMain(VSOut i) : SV_Target { return Tex.Sample(Smp, i.uv); }
        """;

    private readonly int _srcWidth;
    private readonly int _srcHeight;

    private ID3D11Device _device = null!;
    private ID3D11DeviceContext _ctx = null!;
    private IDXGISwapChain1 _swapChain = null!;
    private ID3D11RenderTargetView _rtv = null!;
    private ID3D11Texture2D _srcTex = null!;
    private ID3D11ShaderResourceView _srv = null!;
    private ID3D11SamplerState _sampler = null!;
    private ID3D11VertexShader _vs = null!;
    private ID3D11PixelShader _ps = null!;

    private int _width;
    private int _height;

    public D3DScreen(SwapChainPanel panel, int srcWidth, int srcHeight)
    {
        _srcWidth = srcWidth;
        _srcHeight = srcHeight;
        _width = Math.Max(1, (int)(panel.ActualWidth * panel.CompositionScaleX));
        _height = Math.Max(1, (int)(panel.ActualHeight * panel.CompositionScaleY));

        D3D11CreateDevice(
            null, DriverType.Hardware,
            DeviceCreationFlags.BgraSupport,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 },
            out _device, out _ctx).CheckError();

        using var dxgiDevice = _device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();

        var scd = new SwapChainDescription1
        {
            Width = (uint)_width,
            Height = (uint)_height,
            Format = Format.B8G8R8A8_UNorm,
            Stereo = false,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            Scaling = Scaling.Stretch,
            SwapEffect = SwapEffect.FlipSequential,
            AlphaMode = AlphaMode.Premultiplied,
        };
        _swapChain = factory.CreateSwapChainForComposition(_device, scd);

        // Bind the swapchain to the XAML panel via the native COM interface.
        var nativePanel = panel.As<ISwapChainPanelNative>();
        int hr = nativePanel.SetSwapChain(_swapChain.NativePointer);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);

        CreateRenderTarget();
        CreateSourceTexture();
        CreatePipeline();
    }

    private void CreateRenderTarget()
    {
        using var backbuffer = _swapChain.GetBuffer<ID3D11Texture2D>(0);
        _rtv = _device.CreateRenderTargetView(backbuffer);
    }

    private void CreateSourceTexture()
    {
        _srcTex = _device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)_srcWidth,
            Height = (uint)_srcHeight,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write,
        });
        _srv = _device.CreateShaderResourceView(_srcTex);
    }

    private void CreatePipeline()
    {
        // Vortice's Compiler.Compile returns the compiled bytecode as ReadOnlyMemory<byte>.
        ReadOnlyMemory<byte> vsBlob = Vortice.D3DCompiler.Compiler.Compile(Hlsl, "VSMain", "screen", "vs_5_0");
        ReadOnlyMemory<byte> psBlob = Vortice.D3DCompiler.Compiler.Compile(Hlsl, "PSMain", "screen", "ps_5_0");
        _vs = _device.CreateVertexShader(vsBlob.Span);
        _ps = _device.CreatePixelShader(psBlob.Span);

        _sampler = _device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipPoint,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            ComparisonFunc = ComparisonFunction.Never,
            MinLOD = 0,
            MaxLOD = float.MaxValue,
        });
    }

    /// <summary>Recreate the back buffer after the panel resizes.</summary>
    public void Resize(int width, int height)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        if (width == _width && height == _height) return;
        _width = width;
        _height = height;

        _rtv.Dispose();
        _swapChain.ResizeBuffers(2, (uint)_width, (uint)_height, Format.B8G8R8A8_UNorm, SwapChainFlags.None);
        CreateRenderTarget();
    }

    /// <summary>Upload the RGBA frame and present it.</summary>
    public void Present(ReadOnlySpan<byte> rgba)
    {
        int srcRowBytes = _srcWidth * 4;

        var map = _ctx.Map(_srcTex, 0, MapMode.WriteDiscard);
        try
        {
            byte* dst = (byte*)map.DataPointer;
            fixed (byte* src = rgba)
            {
                for (int y = 0; y < _srcHeight; y++)
                    Buffer.MemoryCopy(src + y * srcRowBytes, dst + y * map.RowPitch, srcRowBytes, srcRowBytes);
            }
        }
        finally
        {
            _ctx.Unmap(_srcTex, 0);
        }

        // Aspect-correct letterbox so 640×400 (4:2.5) isn't distorted.
        var (vx, vy, vw, vh) = LetterboxViewport();
        _ctx.OMSetRenderTargets(_rtv);
        _ctx.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(vx, vy, vw, vh, 0f, 1f));
        _ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        _ctx.VSSetShader(_vs);
        _ctx.PSSetShader(_ps);
        _ctx.PSSetShaderResource(0, _srv);
        _ctx.PSSetSampler(0, _sampler);
        _ctx.Draw(3, 0);

        _swapChain.Present(1, PresentFlags.None);
    }

    private (float x, float y, float w, float h) LetterboxViewport()
    {
        float targetAspect = (float)_srcWidth / _srcHeight;
        float panelAspect = (float)_width / _height;
        if (panelAspect > targetAspect)
        {
            float w = _height * targetAspect;
            return ((_width - w) * 0.5f, 0f, w, _height);
        }
        else
        {
            float h = _width / targetAspect;
            return (0f, (_height - h) * 0.5f, _width, h);
        }
    }

    public void Dispose()
    {
        _sampler?.Dispose();
        _ps?.Dispose();
        _vs?.Dispose();
        _srv?.Dispose();
        _srcTex?.Dispose();
        _rtv?.Dispose();
        _swapChain?.Dispose();
        _ctx?.Dispose();
        _device?.Dispose();
    }
}
