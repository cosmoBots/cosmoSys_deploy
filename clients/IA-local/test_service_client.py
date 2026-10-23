import hashlib
import unittest
from unittest.mock import patch
import service_client


class ClientTests(unittest.TestCase):
    def test_mismatched_preview_never_committed(self):
        preview={'text':'changed','content_sha256':'wrong','destination':'cosmosys','project':'demo'}
        with patch.object(service_client,'call',return_value=preview) as call:
            with self.assertRaises(ValueError):
                service_client.publish_reviewed('cosmoSys','demo','reviewed','id')
            self.assertEqual(1,call.call_count)

    def test_exact_review_commits(self):
        preview=dict(text='reviewed',content_sha256=hashlib.sha256(b'reviewed').hexdigest(),
                     destination='cosmosys',project='demo',review_token='token')
        with patch.object(service_client,'call',side_effect=[preview,{'url':'done'}]) as call:
            self.assertEqual('done',service_client.publish_reviewed('cosmoSys','demo','reviewed','id'))
            self.assertTrue(call.call_args.args[2]['confirmed'])
