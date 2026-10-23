import unittest
from unittest.mock import patch
import rest_adapter as api


class RestAdapterTests(unittest.TestCase):
    def test_review_never_applies_changes(self):
        changes=[{'key':'issue:1'}]
        with patch.object(api,'request',return_value={}) as request:
            api.server('cosmoSys','a/b','check',changes)
            request.assert_called_once_with('cosmoSys',
                '/projects/a%2Fb/exchange/v1/changes.json',
                {'changes':changes,'dry_run':True})

    def test_apply_requires_explicit_operation(self):
        with patch.object(api,'request',return_value={}) as request:
            api.server('CGRol','demo','apply',[])
            self.assertFalse(request.call_args.args[2]['dry_run'])
        with self.assertRaises(ValueError):
            api.server('cosmoSys','demo','delete',[])

    def test_unknown_service_rejected(self):
        with self.assertRaises(ValueError):
            api.base_url('untrusted')
