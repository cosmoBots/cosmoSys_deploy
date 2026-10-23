import json
import unittest
from minutes import Minutes


class FakeInference:
    def __init__(self, citation):
        self.citation = citation
    def chat(self, payload):
        return {'message':{'content':json.dumps({
            'temas':[{'texto':'Revisión','cita':self.citation}],
            'decisiones':[], 'acciones':[], 'pendientes':[]})}}


class MinutesTests(unittest.TestCase):
    def test_evidence_required(self):
        with self.assertRaises(ValueError):
            Minutes(FakeInference('inventado')).draft('Revisamos el proyecto.')

    def test_draft_uses_replaceable_provider(self):
        result=Minutes(FakeInference('Revisamos el proyecto.')).draft('Revisamos el proyecto.')
        self.assertIn('Requiere revisión humana',result)
        self.assertIn('Revisamos el proyecto.',result)

    def test_no_silent_truncation(self):
        with self.assertRaises(ValueError):
            Minutes(FakeInference('')).draft('x'*42001)
