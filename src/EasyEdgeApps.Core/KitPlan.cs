namespace EasyEdgeApps.Core;

public sealed record PortableIcon(string Kind = "Generated", int Version = 1, string? Data = null, string? Sha256 = null);
public sealed record KitApp(string Name, string Url, bool Desktop = true, bool StartMenu = true, string Notes = "", PortableIcon? Icon = null, bool FreshSession = false);
public sealed record AppKit(int SchemaVersion, string Name, KitApp[] Apps, string Notes = "");
public sealed record KitPlanRow(KitApp Source, AppDefinition? Current, AppDefinition? Effective, string Action, string Detail);

public static class KitPlanner
{
    public static KitPlanRow[] Preview(AppKit kit, IReadOnlyCollection<AppDefinition> destination)
    {
        if (kit.SchemaVersion is not (1 or 2) || kit.Apps.Length is < 1 or > 100) throw new ValidationException("Use a version 1 or 2 App Kit containing between 1 and 100 apps.");
        var resolved = new HashSet<string>(StringComparer.Ordinal);
        var names = new HashSet<string>(StringComparer.Ordinal);
        var rows = new List<KitPlanRow>();
        foreach (var source in kit.Apps)
        {
            AppDefinition? current = null;
            try
            {
                var nameKey = Identity.NameKey(source.Name);
                if (!names.Add(nameKey)) throw new ValidationException("The kit contains duplicate normalized names.");
                var matches = destination.Where(app => Identity.NameKey(app.DisplayName) == nameKey || app.Aliases.Any(alias => Identity.NameKey(alias) == nameKey)).ToArray();
                if (matches.Length > 1) throw new ValidationException("This name matches more than one reserved identity.");
                current = matches.SingleOrDefault();
                var effective = Apply(source, kit.SchemaVersion, current);
                if (!resolved.Add(effective.Id)) throw new ValidationException("Multiple kit entries resolve to the same permanent identity.");
                rows.Add(new(source, current, effective, current is null ? "Add" : "Update", current is null ? "Create selected shortcuts." : "Preserve destination-local identity, profile and window choices."));
            }
            catch (ValidationException failure) { rows.Add(new(source, current, null, "Conflict", failure.Message)); }
        }
        return rows.ToArray();
    }

    public static AppDefinition Apply(KitApp source, int schemaVersion, AppDefinition? current)
    {
        if (schemaVersion is not (1 or 2)) throw new ValidationException("Unsupported App Kit schema.");
        var baseline = current ?? new AppDefinition { DisplayName = Identity.Name(source.Name) };
        return (baseline with
        {
            Url = source.Url, Notes = source.Notes, Desktop = source.Desktop, StartMenu = source.StartMenu,
            IconKind = source.Icon?.Kind == "Embedded" ? "Custom" : "Generated",
            Window = baseline.Window with { FreshSession = schemaVersion == 1 ? baseline.Window.FreshSession : source.FreshSession }
        }).Normalize();
    }
}