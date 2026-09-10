using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json.Serialization;

namespace EasyEdgeApps.Core;

public sealed class ValidationException(string message) : Exception(message);

public enum LaunchMode { RememberLast, Maximized, FullScreen }

public sealed record WindowSettings
{
    public bool FreshSession { get; init; }
    public bool DedicatedProfile { get; init; } = true;
    public bool Taskbar { get; init; }
    public LaunchMode LaunchMode { get; init; } = LaunchMode.RememberLast;
    public bool AlwaysOnTop { get; init; }
    [JsonIgnore] public bool Owned => FreshSession || DedicatedProfile;
    [JsonIgnore] public string BrowsingMode => FreshSession ? "Fresh Guest session (temporary)" : DedicatedProfile ? "Dedicated app profile (persistent)" : "Normal Edge profile";

    public void Validate(bool startMenu)
    {
        if (!Enum.IsDefined(LaunchMode)) throw new ValidationException("Unknown window mode.");
        if (Taskbar && (!startMenu || !DedicatedProfile)) throw new ValidationException("Taskbar apps require a Start entry and a dedicated profile.");
        if (AlwaysOnTop && LaunchMode == LaunchMode.FullScreen) throw new ValidationException("Always on top is available for remembered or maximized windows, not full screen.");
        if (!Owned && (AlwaysOnTop || LaunchMode == LaunchMode.FullScreen))
            throw new ValidationException("Full screen and Always on top require a dedicated or Fresh profile. Change the local window or profile choice explicitly before importing; normal Edge data is never copied.");
    }
}

public sealed record AppDefinition
{
    public string Id { get; init; } = Identity.NewId();
    public string DisplayName { get; init; } = "";
    public string[] Aliases { get; init; } = [];
    public string Url { get; init; } = "";
    public string Notes { get; init; } = "";
    public string EdgeProfile { get; init; } = "";
    public bool Desktop { get; init; } = true;
    public bool StartMenu { get; init; } = true;
    public WindowSettings Window { get; init; } = new();
    public string IconKind { get; init; } = "Generated";

    public AppDefinition Normalize()
    {
        if (Window is null || Aliases is null || Aliases.Any(alias => alias is null) || DisplayName is null || Url is null || Notes is null || EdgeProfile is null)
            throw new ValidationException("Website settings have null required fields.");
        if (!Identity.IsId(Id)) throw new ValidationException("Invalid permanent website identity.");
        if (!Desktop && !StartMenu) throw new ValidationException("Choose Desktop, Start menu, or both.");
        Window.Validate(StartMenu);
        if (IconKind is not ("Generated" or "Custom")) throw new ValidationException("Invalid icon kind.");
        if (Aliases.Length > 100) throw new ValidationException("Too many historical website names.");
        return this with
        {
            DisplayName = Identity.Name(DisplayName), Url = Identity.Website(Url), Notes = Identity.Notes(Notes),
            EdgeProfile = Identity.Profile(EdgeProfile), Aliases = Aliases.Select(Identity.Name).Distinct(StringComparer.Ordinal).ToArray()
        };
    }
}

public static class Identity
{
    public static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
    public static bool IsId(string? value) => value is not null && Regex.IsMatch(value, "\\A[a-f0-9]{64}\\z", RegexOptions.CultureInvariant);
    public static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
    public static string NameKey(string value) => Name(value).ToUpperInvariant();
    public static string LegacyId(string name) => Hash(Encoding.UTF8.GetBytes(NameKey(name)));

    public static string Name(string value)
    {
        var clean = value.Trim().Normalize(NormalizationForm.FormC);
        if (clean.Length is < 1 or > 60 || clean.EndsWith('.') || Regex.IsMatch(clean, "[<>:\"/\\\\|?*\\p{Cc}\\p{Cf}]") ||
            Regex.IsMatch(clean, @"\A(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\..*)?\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            throw new ValidationException("Use a Windows-safe website name of 1 to 60 characters.");
        return clean;
    }

    public static string Website(string value, bool allowMissingScheme = false)
    {
        var clean = value.Trim();
        if (allowMissingScheme && !Regex.IsMatch(clean, "\\Ahttps?://", RegexOptions.IgnoreCase))
        {
            if (clean.Length == 0 || Regex.IsMatch(clean, @"\A[/?#]") ||
                (Regex.IsMatch(clean, @"\A[a-z][a-z0-9+.-]*:", RegexOptions.IgnoreCase) && !Regex.IsMatch(clean, @"\A[^/?#:\s]+:[0-9]+(?:[/?#]|$)")))
                throw new ValidationException("Enter a website host or an HTTP/HTTPS address.");
            clean = "https://" + clean;
        }
        if (clean.Length > 2048 || Regex.IsMatch(clean, "[\\s\\p{Cc}\\p{Cf}\"\\\\]") || !Regex.IsMatch(clean, "\\Ahttps?://", RegexOptions.IgnoreCase) ||
            !Uri.TryCreate(clean, UriKind.Absolute, out var uri) || uri.UserInfo.Length != 0 || string.IsNullOrWhiteSpace(uri.Host) || !uri.IsWellFormedOriginalString())
            throw new ValidationException("Use a complete HTTP/HTTPS address without credentials, spaces, quotes, or control characters.");
        var canonical = new UriBuilder(uri) { Host = uri.IdnHost }.Uri.AbsoluteUri;
        if (canonical.Length > 2048) throw new ValidationException("The encoded address exceeds 2048 characters.");
        return canonical;
    }

    public static string Notes(string value)
    {
        if (value.Length > 4000 || Regex.IsMatch(value, @"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\p{Cf}]"))
            throw new ValidationException("Use plain-text notes of at most 4000 characters.");
        return value;
    }

    public static string Profile(string value)
    {
        if (value != "" && value != "Default" && !Regex.IsMatch(value, @"\AProfile [0-9]{1,6}\z"))
            throw new ValidationException("Use Default or a numbered Edge profile directory.");
        return value;
    }
}