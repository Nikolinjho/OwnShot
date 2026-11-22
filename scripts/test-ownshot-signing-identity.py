#!/usr/bin/env python3
"""Защита от запроса экспорта закрытого ключа при проверке идентичности."""
from pathlib import Path
import re
import unittest


SOURCE = Path(__file__).with_name("ownshot-signing-identity.swift").read_text()


class SigningIdentitySourceTests(unittest.TestCase):
    def test_private_key_attributes_cannot_trigger_export(self):
        self.assertNotIn("SecKeyCopyAttributes", SOURCE)
        self.assertNotIn("SecItemExport", SOURCE)
        self.assertNotIn("SecKeychainItemExport", SOURCE)

    def test_external_representation_is_only_used_for_public_keys(self):
        arguments = re.findall(r"SecKeyCopyExternalRepresentation\(\s*(\w+)", SOURCE)
        self.assertCountEqual(arguments, ["publicKey", "certKey"])
        self.assertIn("let publicKey = SecKeyCopyPublicKey(key)", SOURCE)
        self.assertIn("let certKey = SecCertificateCopyKey(certificate)", SOURCE)

    def test_legacy_attribute_read_never_requests_key_data(self):
        calls = re.findall(r"SecKeychainItemCopyAttributesAndData\(([^\n]+)", SOURCE)
        self.assertEqual(len(calls), 1)
        self.assertIn("&info, nil, &list, nil, nil)", calls[0])

    def test_security_metadata_is_verified(self):
        for attribute in ("kSecKeyExtractable", "kSecKeyPermanent", "kSecKeyKeySizeInBits", "kSecKeyKeyType"):
            self.assertRegex(SOURCE, rf"legacyKeyUInt32\(key, tag: {attribute}\)")

    def test_creation_forbids_private_key_export(self):
        self.assertRegex(SOURCE, r"kSecUseKeychain: keychain,\s*kSecAttrIsExtractable: false,\s*kSecAttrAccess: access")
        self.assertIn("kSecAttrIsSensitive: true", SOURCE)
        self.assertIn("kSecAttrApplicationTag: keyTag", SOURCE)


if __name__ == "__main__":
    unittest.main()
