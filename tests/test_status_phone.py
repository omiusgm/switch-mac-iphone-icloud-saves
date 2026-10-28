from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import status_phone as s


class PhoneProofTests(unittest.TestCase):
    def test_complete_parts_and_wrong_or_truncated_proofs(self):
        sha = 'a' * 64
        def part(size):
            return s.PROOF_RECORD.pack(b'TOTKRFS-PROOF-1', sha.encode(), 1, 2, size, 0, 0, 0, 0, 0, 0)
        blob = part(100) + part(200)
        self.assertTrue(s.proof_matches(blob, sha, 300))
        self.assertFalse(s.proof_matches(blob, sha, 299))
        self.assertFalse(s.proof_matches(blob, 'b' * 64, 300))
        self.assertFalse(s.proof_matches(blob[:-1], sha, 300))
        self.assertFalse(s.proof_matches(b'', sha, 0))


if __name__ == '__main__': unittest.main()
