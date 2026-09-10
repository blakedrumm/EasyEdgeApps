using System.Text;
using System.Text.Json;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class PortableTests
{
    [Fact]
    public void EncryptionMatchesPublishedRfc7518AppendixB3()
    {
        var key = Enumerable.Range(0, 64).Select(value => (byte)value).ToArray();
        var iv = Convert.FromHexString("1af38c2dc2b96ffdd86694092341bc04");
        var associated = Encoding.ASCII.GetBytes("The second principle of Auguste Kerckhoffs");
        var plaintext = Encoding.ASCII.GetBytes("A cipher system must not be required to be secret, and it must be able to fall into the hands of the enemy without inconvenience");
        var expected = Convert.FromHexString("4affaaadb78c31c5da4b1b590d10ffbd3dd8d5d302423526912da037ecbcc7bd822c301dd67c373bccb584ad3e9279c2e6d12a1374b77f077553df829410446b36ebd97066296ae6427ea75c2e0846a11a09ccf5370dc80bfecbad28c73f09b3a3b75e662a2594410ae496b2e2e6609e31e6e02cc837f053d21f37ff4f51950bbe2638d09dd7a4930930806d0703b1f6");
        var tag = Convert.FromHexString("4dd3b4c088a7f45c216839645b2012bf2e6269a8c56a816dbc1b267761955bc5");
        var encrypted = KitEncryption.ProtectBytes(key, iv, associated, plaintext);
        Assert.Equal(expected, encrypted.Ciphertext);
        Assert.Equal(tag, encrypted.Tag);
        Assert.Equal(plaintext, KitEncryption.UnprotectBytes(key, iv, associated, expected, tag));
    }

    [Fact]
    public void ExperimentalEncryptionRoundTripsAndAuthenticatesMetadata()
    {
        var kit = new AppKit(2, "Private kit", [new("News", "https://example.com/?q=private", Notes: "2026-09-09T00:00:00Z", FreshSession: true)]);
        var encrypted = KitEncryption.Protect(kit, "Synthetic passphrase 123", "Synthetic passphrase 123");
        Assert.DoesNotContain("private", Encoding.UTF8.GetString(encrypted));
        var opened = KitEncryption.Unlock(encrypted, "Synthetic passphrase 123");
        Assert.Equal(kit.Apps[0].Notes, opened.Apps[0].Notes);
        Assert.True(opened.Apps[0].FreshSession);
        Assert.Throws<ValidationException>(() => KitEncryption.Unlock(encrypted, "Wrong synthetic passphrase"));
        var envelope = KitEncryption.ReadEnvelope(encrypted);
        Assert.Throws<ValidationException>(() => KitEncryption.Unlock(JsonSerializer.SerializeToUtf8Bytes(envelope with { Iterations = 600001 }), "Synthetic passphrase 123"));
        Assert.Throws<ValidationException>(() => KitEncryption.ReadEnvelope(JsonSerializer.SerializeToUtf8Bytes(envelope with { Iterations = 599999 })));
        Assert.Throws<ValidationException>(() => KitEncryption.ReadEnvelope(JsonSerializer.SerializeToUtf8Bytes(envelope with { Salt = envelope.Salt + " " })));
        Assert.Contains("experimental", KitEncryption.Warning);
    }

    [Fact]
    public void EveryCiphertextAndTagMutationIsRejected()
    {
        var key = Enumerable.Range(0, 64).Select(value => (byte)value).ToArray();
        var iv = Enumerable.Range(32, 16).Select(value => (byte)value).ToArray();
        var associated = "associated data"u8.ToArray();
        var plain = "synthetic plaintext"u8.ToArray();
        var encrypted = KitEncryption.ProtectBytes(key, iv, associated, plain);
        Assert.Equal(plain, KitEncryption.UnprotectBytes(key, iv, associated, encrypted.Ciphertext, encrypted.Tag));
        for (var index = 0; index < encrypted.Ciphertext.Length; index++)
        {
            var changed = encrypted.Ciphertext.ToArray(); changed[index] ^= 1;
            Assert.Throws<ValidationException>(() => KitEncryption.UnprotectBytes(key, iv, associated, changed, encrypted.Tag));
        }
        for (var index = 0; index < encrypted.Tag.Length; index++)
        {
            var changed = encrypted.Tag.ToArray(); changed[index] ^= 1;
            Assert.Throws<ValidationException>(() => KitEncryption.UnprotectBytes(key, iv, associated, encrypted.Ciphertext, changed));
        }
    }

    [Fact]
    public void FavoritesAreReadOnlyBoundedAndRejectUnsafeAddresses()
    {
        var bytes = """
            {"roots":{"bookmark_bar":{"type":"folder","name":"Favorites","children":[
              {"type":"url","name":"News","url":"https://example.com/"},
              {"type":"url","name":"News","url":"https://example.org:8080/"},
              {"type":"url","name":"Unsafe","url":"https://user:password@example.org/"},
              {"type":"url","name":"Script","url":"javascript:alert(1)"},
              {"type":"url","name":"HTTP","url":"http://example.net/"}
            ]}}}
            """u8.ToArray();
        var hash = Identity.Hash(bytes);
        var candidates = Favorites.Read(bytes, [new() { DisplayName = "News", Url = "https://example.com/" }]);
        Assert.False(candidates[0].CanImport);
        Assert.True(candidates[1].CanImport);
        Assert.Equal("News (2)", candidates[1].Name);
        Assert.All(candidates.Skip(2), candidate => Assert.False(candidate.CanImport));
        Assert.Single(Favorites.ToKit(candidates.Where(candidate => candidate.CanImport)).Apps);
        Assert.Equal(hash, Identity.Hash(bytes));
    }

    [Theory]
    [InlineData("", "example.com")]
    [InlineData("  Work   Portal.  ", "Work Portal")]
    [InlineData("CON", "Website CON")]
    public void FavoriteNamesMatchTheOriginalNormalization(string title, string expected)
    {
        var bytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new { roots = new { bookmark_bar = new { type = "folder", name = "Favorites bar", children = new[] { new { type = "url", name = title, url = "https://example.com/" } } } } });
        var favorite = Assert.Single(Favorites.Read(bytes, []));
        Assert.Equal(expected, favorite.Name);
        Assert.Equal("", favorite.Folder);
        Assert.True(favorite.CanImport);
        var invalid = new FavoriteCandidate("HTTP", "http://example.com/", "", true, "Synthetic caller");
        Assert.Throws<ValidationException>(() => Favorites.ToKit([invalid]));
    }

    [Fact]
    public async Task FailedSaveCanBeRetriedWithoutEditing()
    {
        using var editor = new EditorSession(new() { DisplayName = "News", Url = "https://example.com/" });
        editor.Edit(editor.Draft with { Definition = editor.Draft.Definition with { Notes = "Retry me" } });
        Assert.False(await editor.SaveAsync((_, _) => throw new IOException("Locked")));
        Assert.True(await editor.SaveAsync((draft, _) => Task.FromResult(draft.Definition)));
        Assert.False(editor.IsDirty);
    }
}