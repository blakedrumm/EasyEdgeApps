using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace EasyEdgeApps.Core;

public sealed record EncryptedEnvelope(string Product, int SchemaVersion, string Algorithm, string Kdf, int Iterations, string Salt, string Iv, string Ciphertext, string Tag);

public static class KitEncryption
{
    public const string Warning = "Encrypted App Kits are experimental and have not received an independent cryptographic audit.";
    private const int MaximumCiphertext = 16 * 1024 * 1024 + 16;
    private const int ExportIterations = 600000;

    public static byte[] Protect(AppKit kit, ReadOnlySpan<char> password, ReadOnlySpan<char> confirmation, CancellationToken cancellationToken = default)
    {
        if (password.Length is < 12 or > 1024 || confirmation.Length is < 1 or > 1024) throw new ValidationException("Choose a passphrase of 12 to 1024 characters and confirm it.");
        var passwordBytes = PasswordBytes(password);
        var confirmationBytes = PasswordBytes(confirmation);
        byte[]? key = null;
        byte[]? plaintext = null;
        try
        {
            if (!CryptographicOperations.FixedTimeEquals(passwordBytes, confirmationBytes)) throw new ValidationException("The passphrases do not match.");
            cancellationToken.ThrowIfCancellationRequested();
            plaintext = KitCodec.Write(kit);
            var salt = RandomNumberGenerator.GetBytes(16);
            var iv = RandomNumberGenerator.GetBytes(16);
            var saltText = Convert.ToBase64String(salt);
            key = Rfc2898DeriveBytes.Pbkdf2(passwordBytes, salt, ExportIterations, HashAlgorithmName.SHA256, 64);
            cancellationToken.ThrowIfCancellationRequested();
            var encrypted = ProtectBytes(key, iv, AssociatedData(ExportIterations, saltText), plaintext);
            return JsonSerializer.SerializeToUtf8Bytes(new EncryptedEnvelope("EasyEdgeApps.EncryptedKit", 1, "A256CBC-HS512", "PBKDF2-HMAC-SHA256", ExportIterations,
                saltText, Convert.ToBase64String(iv), Convert.ToBase64String(encrypted.Ciphertext), Convert.ToBase64String(encrypted.Tag)));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(passwordBytes); CryptographicOperations.ZeroMemory(confirmationBytes);
            if (key is not null) CryptographicOperations.ZeroMemory(key);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public static AppKit Unlock(byte[] bytes, ReadOnlySpan<char> password, CancellationToken cancellationToken = default)
    {
        var envelope = ReadEnvelope(bytes);
        var salt = StrictJson.Base64(envelope.Salt, 16, 16);
        var iv = StrictJson.Base64(envelope.Iv, 16, 16);
        var ciphertext = StrictJson.Base64(envelope.Ciphertext, MaximumCiphertext);
        var tag = StrictJson.Base64(envelope.Tag, 32, 32);
        var passwordBytes = PasswordBytes(password);
        byte[]? key = null;
        byte[]? plaintext = null;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            key = Rfc2898DeriveBytes.Pbkdf2(passwordBytes, salt, envelope.Iterations, HashAlgorithmName.SHA256, 64);
            cancellationToken.ThrowIfCancellationRequested();
            plaintext = UnprotectBytes(key, iv, AssociatedData(envelope.Iterations, envelope.Salt), ciphertext, tag);
            return KitCodec.Read(plaintext);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(passwordBytes);
            if (key is not null) CryptographicOperations.ZeroMemory(key);
            if (plaintext is not null) CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public static EncryptedEnvelope ReadEnvelope(byte[] bytes)
    {
        using var document = StrictJson.Parse(bytes, 24 * 1024 * 1024);
        var root = document.RootElement;
        StrictJson.Fields(root, ["Product", "SchemaVersion", "Algorithm", "Kdf", "Iterations", "Salt", "Iv", "Ciphertext", "Tag"]);
        var envelope = new EncryptedEnvelope(StrictJson.Text(root, "Product"), StrictJson.Integer(root, "SchemaVersion"), StrictJson.Text(root, "Algorithm"), StrictJson.Text(root, "Kdf"),
            StrictJson.Integer(root, "Iterations"), StrictJson.Text(root, "Salt"), StrictJson.Text(root, "Iv"), StrictJson.Text(root, "Ciphertext"), StrictJson.Text(root, "Tag"));
        if (envelope.Product != "EasyEdgeApps.EncryptedKit" || envelope.SchemaVersion != 1 || envelope.Algorithm != "A256CBC-HS512" || envelope.Kdf != "PBKDF2-HMAC-SHA256" || envelope.Iterations is < 600000 or > 1200000)
            throw new ValidationException("Unsupported encrypted App Kit version, algorithm or key derivation parameters.");
        _ = StrictJson.Base64(envelope.Salt, 16, 16); _ = StrictJson.Base64(envelope.Iv, 16, 16); _ = StrictJson.Base64(envelope.Tag, 32, 32);
        var ciphertext = StrictJson.Base64(envelope.Ciphertext, MaximumCiphertext);
        if (ciphertext.Length < 16 || ciphertext.Length % 16 != 0) throw new ValidationException("Invalid encrypted payload length.");
        return envelope;
    }

    public static (byte[] Ciphertext, byte[] Tag) ProtectBytes(byte[] key, byte[] iv, byte[] associatedData, byte[] plaintext)
    {
        if (key.Length != 64 || iv.Length != 16 || associatedData.Length > 1024 || plaintext.Length > 16 * 1024 * 1024) throw new ValidationException("Invalid encryption input bounds.");
        var encryptionKey = key[32..];
        try
        {
            using var aes = Aes.Create(); aes.Key = encryptionKey;
            var ciphertext = aes.EncryptCbc(plaintext, iv, PaddingMode.PKCS7);
            return (ciphertext, Tag(key, iv, associatedData, ciphertext));
        }
        finally { CryptographicOperations.ZeroMemory(encryptionKey); }
    }

    public static byte[] UnprotectBytes(byte[] key, byte[] iv, byte[] associatedData, byte[] ciphertext, byte[] tag)
    {
        if (!CryptographicOperations.FixedTimeEquals(Tag(key, iv, associatedData, ciphertext), tag)) throw new ValidationException("Incorrect password or damaged kit.");
        var encryptionKey = key[32..];
        try
        {
            using var aes = Aes.Create(); aes.Key = encryptionKey;
            return aes.DecryptCbc(ciphertext, iv, PaddingMode.PKCS7);
        }
        catch (CryptographicException) { throw new ValidationException("Incorrect password or damaged kit."); }
        finally { CryptographicOperations.ZeroMemory(encryptionKey); }
    }

    private static byte[] Tag(byte[] key, byte[] iv, byte[] associatedData, byte[] ciphertext)
    {
        if (key.Length != 64 || iv.Length != 16 || associatedData.Length > 1024 || ciphertext.Length is < 16 or > MaximumCiphertext || ciphertext.Length % 16 != 0)
            throw new ValidationException("Invalid authenticated encryption bounds.");
        var macKey = key[..32];
        try
        {
            using var hmac = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA512, macKey);
            hmac.AppendData(associatedData); hmac.AppendData(iv); hmac.AppendData(ciphertext);
            Span<byte> length = stackalloc byte[8];
            BinaryPrimitives.WriteUInt64BigEndian(length, (ulong)associatedData.Length * 8);
            hmac.AppendData(length);
            return hmac.GetHashAndReset()[..32];
        }
        finally { CryptographicOperations.ZeroMemory(macKey); }
    }

    private static byte[] AssociatedData(int iterations, string salt) => Encoding.ASCII.GetBytes(string.Join("\n", "EasyEdgeApps.EncryptedKit", "1", "A256CBC-HS512", "PBKDF2-HMAC-SHA256", iterations.ToString(CultureInfo.InvariantCulture), salt));

    private static byte[] PasswordBytes(ReadOnlySpan<char> password)
    {
        if (password.Length is < 1 or > 1024) throw new ValidationException("Provide a passphrase of 1 to 1024 characters.");
        var encoding = new UTF8Encoding(false, true);
        var bytes = new byte[encoding.GetByteCount(password)];
        encoding.GetBytes(password, bytes);
        return bytes;
    }
}