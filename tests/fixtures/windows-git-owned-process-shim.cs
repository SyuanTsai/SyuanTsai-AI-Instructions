// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class WindowsGitOwnedProcessShim
{
    private static string ReadSetting(string root, string name)
    {
        return File.ReadAllText(Path.Combine(root, name), Encoding.UTF8).Trim();
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length != 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
        {
            return value;
        }

        var result = new StringBuilder();
        result.Append('"');
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }
            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static int ObserveCredentialsAndRunGit(string root, string[] arguments)
    {
        var observationPath = ReadSetting(root, "observation-path.txt");
        var names = new[] { "STANDARD_VALIDATION_GITHUB_API_TOKEN", "GITHUB_TOKEN", "GH_TOKEN" };
        var observations = new string[names.Length];
        for (var index = 0; index < names.Length; index++)
        {
            observations[index] = Environment.GetEnvironmentVariable(names[index]) == null ? "0" : "1";
        }
        File.AppendAllText(observationPath, string.Join(",", observations) + Environment.NewLine, new UTF8Encoding(false));

        var start = new ProcessStartInfo
        {
            FileName = ReadSetting(root, "real-git-path.txt"),
            Arguments = string.Join(" ", Array.ConvertAll(arguments, QuoteArgument)),
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using (var process = Process.Start(start))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static int RunHangMode(string root, bool descendant)
    {
        var pidPath = ReadSetting(root, descendant ? "descendant-pid-path.txt" : "shim-pid-path.txt");
        File.WriteAllText(pidPath, Process.GetCurrentProcess().Id.ToString(), new UTF8Encoding(false));
        if (!descendant)
        {
            var start = new ProcessStartInfo
            {
                FileName = Process.GetCurrentProcess().MainModule.FileName,
                Arguments = "--owned-process-descendant",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process.Start(start);
        }
        Thread.Sleep(Timeout.Infinite);
        return 0;
    }

    private static int Main(string[] arguments)
    {
        try
        {
            var root = AppDomain.CurrentDomain.BaseDirectory;
            var mode = ReadSetting(root, "mode.txt");
            if (string.Equals(mode, "credential", StringComparison.Ordinal))
            {
                return ObserveCredentialsAndRunGit(root, arguments);
            }
            if (string.Equals(mode, "hang", StringComparison.Ordinal))
            {
                return RunHangMode(root, arguments.Length == 1 &&
                    string.Equals(arguments[0], "--owned-process-descendant", StringComparison.Ordinal));
            }
            Console.Error.WriteLine("Unknown Windows Git shim mode.");
            return 2;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.ToString());
            return 3;
        }
    }
}
