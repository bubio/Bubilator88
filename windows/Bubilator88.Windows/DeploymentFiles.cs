using System;
using System.Diagnostics;
using System.IO;

namespace Bubilator88.Windows;

/// <summary>Locates loose content in folder builds and extracted single-file bundles.</summary>
internal static class DeploymentFiles
{
    public static string? Find(string relativePath)
    {
        string besideExe = Path.Combine(AppContext.BaseDirectory, relativePath);
        if (File.Exists(besideExe)) return besideExe;

        // .NET 10 keeps AppContext.BaseDirectory at the EXE, while WinUI and
        // content are extracted elsewhere. The runtime includes that directory
        // among its native DLL search paths when running a bundle.
        if (AppContext.GetData("NATIVE_DLL_SEARCH_DIRECTORIES") is string paths)
        {
            foreach (string directory in paths.Split(Path.PathSeparator,
                         StringSplitOptions.RemoveEmptyEntries))
            {
                string candidate = Path.Combine(directory, relativePath);
                if (File.Exists(candidate)) return candidate;
            }
        }

        // The Swift core is loaded by P/Invoke before AI setup. Its module path
        // gives a final fallback if the runtime omits the extraction search path.
        foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
        {
            if (!string.Equals(module.ModuleName, "Bubilator88C.dll",
                               StringComparison.OrdinalIgnoreCase)) continue;
            string candidate = Path.Combine(Path.GetDirectoryName(module.FileName)!, relativePath);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
