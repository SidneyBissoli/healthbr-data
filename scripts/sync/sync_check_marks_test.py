"""
Testes das marcas de conferência por partição (S2, 2026-10-09).

O sync-check grava em cada partição que CONFERIU igual à fonte
`last_checked_at` + `check_method = "size"`, e regrava o manifesto com
`If-Match` no ETag lido. O que estes testes provam, sem rede e sem R2:

- a marca só nasce de uma comparação de tamanho que aconteceu (status
  `in_sync` com tamanho dos dois lados); `outdated`, `missing`, `check_failed`
  e partição sem tamanho registrado não ganham instante;
- a aplicação não toca o cabeçalho (`last_updated` é a edição dos DADOS) nem
  partição ausente ou reescrita pelo pipeline depois do LIST;
- um 412 (o pipeline reescreveu o manifesto no meio) provoca releitura e
  reaplicação sobre a cópia NOVA — nunca a antiga por cima da nova;
- qualquer outra falha vira `error` no resultado, sem derrubar a rodada;
- o manifest_summary copia e ANUNCIA os dois campos em `summary.fields`.

Rodar:  python scripts/sync/sync_check_marks_test.py
"""

import copy
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import manifest_summary  # noqa: E402
import sync_check  # noqa: E402

QUANDO = "2026-10-13T03:04:05Z"


def parte(size=114153, **extra):
    p = {"source_size_bytes": size, "source_hash_md5": "a2", "processing_timestamp": "2026-03-08 16:37:17",
         "output_files": [{"path": "x", "size_bytes": 1, "sha256": "d6"}]}
    p.update(extra)
    return p


def manifesto(**partes):
    return {"manifest_version": "1.0.0", "dataset": "sih/rd", "last_updated": "2026-09-14T23:17:52",
            "pipeline_version": "1.2.0", "partitions": partes}


class MarcaPorParticao(unittest.TestCase):
    def test_so_in_sync_com_tamanho_igual_dos_dois_lados(self):
        fonte = {"exists": True, "size_bytes": 114153}
        self.assertEqual(
            sync_check.mark_for("in_sync", parte(), fonte, QUANDO),
            {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 114153},
        )
        for status in ("outdated", "missing", "check_failed", "extra", "not_published"):
            with self.subTest(status=status):
                self.assertIsNone(sync_check.mark_for(status, parte(), fonte, QUANDO))

    def test_sem_tamanho_registrado_ou_listado_nao_marca(self):
        # classify() devolve in_sync quando falta um dos tamanhos (não há o que
        # comparar) — isso NÃO é conferência, e a marca não pode afirmar que foi.
        self.assertIsNone(sync_check.mark_for("in_sync", parte(size=None), {"exists": True, "size_bytes": 5}, QUANDO))
        self.assertIsNone(sync_check.mark_for("in_sync", parte(), {"exists": True, "size_bytes": None}, QUANDO))
        self.assertIsNone(sync_check.mark_for("in_sync", None, {"exists": True, "size_bytes": 5}, QUANDO))

    def test_classify_e_mark_for_concordam_no_caso_positivo(self):
        fonte = {"exists": True, "filename": "RDAC0801.DBC", "size_bytes": 114153}
        status, _ = sync_check.classify(True, True, parte(), fonte)
        self.assertEqual(status, "in_sync")
        self.assertIsNotNone(sync_check.mark_for(status, parte(), fonte, QUANDO))
        fonte_mudou = dict(fonte, size_bytes=114154)
        status, _ = sync_check.classify(True, True, parte(), fonte_mudou)
        self.assertEqual(status, "outdated")
        self.assertIsNone(sync_check.mark_for(status, parte(), fonte_mudou, QUANDO))


class AplicarMarcas(unittest.TestCase):
    def test_toca_so_as_marcadas_e_nunca_o_cabecalho(self):
        m = manifesto(**{"2008-01-AC": parte(), "2008-01-AL": parte(size=200), "2008-01-AM": parte(size=300)})
        antes = copy.deepcopy(m)
        marcas = {
            "2008-01-AC": {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 114153},
            "2008-01-AL": {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 200},
        }
        self.assertEqual(sync_check.apply_check_marks(m, marcas), 2)
        for k in ("2008-01-AC", "2008-01-AL"):
            self.assertEqual(m["partitions"][k]["last_checked_at"], QUANDO)
            self.assertEqual(m["partitions"][k]["check_method"], "size")
            sem_marca = {c: v for c, v in m["partitions"][k].items() if c not in ("last_checked_at", "check_method")}
            self.assertEqual(sem_marca, antes["partitions"][k])
        self.assertEqual(m["partitions"]["2008-01-AM"], antes["partitions"]["2008-01-AM"])
        for c in ("manifest_version", "dataset", "last_updated", "pipeline_version"):
            self.assertEqual(m[c], antes[c])

    def test_particao_reescrita_ou_ausente_fica_como_esta(self):
        # O pipeline reprocessou AC entre o LIST e a gravação: tamanho novo,
        # marca "md5" dele. A marca "size" velha não pode sobrescrever.
        m = manifesto(**{"2008-01-AC": parte(size=999, last_checked_at="2026-10-13T05:00:00Z", check_method="md5")})
        marcas = {
            "2008-01-AC": {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 114153},
            "2008-01-ZZ": {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 1},
        }
        self.assertEqual(sync_check.apply_check_marks(m, marcas), 0)
        self.assertEqual(m["partitions"]["2008-01-AC"]["check_method"], "md5")
        self.assertNotIn("2008-01-ZZ", m["partitions"])


class ClienteFalso:
    """R2 de mentira: uma sequência de versões do manifesto, ETag por versão."""

    def __init__(self, versoes):
        self.versoes = list(versoes)
        self.leituras = 0
        self.gravacoes = []

    def get_object(self, Bucket, Key):
        self.leituras += 1
        corpo = json.dumps(self.versoes[min(self.leituras, len(self.versoes)) - 1]).encode()
        return {"ETag": f'"v{self.leituras}"', "Body": io.BytesIO(corpo), "ContentType": "application/json"}


class Erro412(Exception):
    response = {"Error": {"Code": "PreconditionFailed"}, "ResponseMetadata": {"HTTPStatusCode": 412}}


class GravarMarcas(unittest.TestCase):
    MARCAS = {"2008-01-AC": {"last_checked_at": QUANDO, "check_method": "size", "source_size_bytes": 114153}}

    def test_grava_com_if_match_no_etag_lido(self):
        cliente = ClienteFalso([manifesto(**{"2008-01-AC": parte()})])
        gravado = []

        def put(c, etag, **kw):
            gravado.append((etag, json.loads(kw["Body"]), kw))

        r = sync_check.write_check_marks(cliente, "sih/rd/manifest.json", self.MARCAS, put=put)
        self.assertEqual(r, {"written": 1, "attempts": 1, "error": None})
        etag, corpo, kw = gravado[0]
        self.assertEqual(etag, '"v1"')
        self.assertEqual(corpo["partitions"]["2008-01-AC"]["last_checked_at"], QUANDO)
        self.assertEqual(corpo["last_updated"], "2026-09-14T23:17:52")
        self.assertEqual(kw["Key"], "sih/rd/manifest.json")
        self.assertEqual(kw["ContentType"], "application/json")

    def test_412_rele_e_reaplica_sobre_a_copia_nova(self):
        velho = manifesto(**{"2008-01-AC": parte()})
        novo = manifesto(**{"2008-01-AC": parte(), "2026-09-SP": parte(size=777)})  # o pipeline publicou SP
        cliente = ClienteFalso([velho, novo])
        gravado = []

        def put(c, etag, **kw):
            if etag == '"v1"':
                raise Erro412()
            gravado.append((etag, json.loads(kw["Body"])))

        r = sync_check.write_check_marks(cliente, "k", self.MARCAS, put=put)
        self.assertEqual(r, {"written": 1, "attempts": 2, "error": None})
        self.assertEqual(cliente.leituras, 2)
        etag, corpo = gravado[0]
        self.assertEqual(etag, '"v2"')
        self.assertIn("2026-09-SP", corpo["partitions"])  # a partição nova sobreviveu
        self.assertEqual(corpo["partitions"]["2008-01-AC"]["last_checked_at"], QUANDO)

    def test_412_persistente_vira_erro_sem_excecao(self):
        cliente = ClienteFalso([manifesto(**{"2008-01-AC": parte()})])

        def put(c, etag, **kw):
            raise Erro412()

        r = sync_check.write_check_marks(cliente, "k", self.MARCAS, put=put, retries=2)
        self.assertEqual(r["written"], 0)
        self.assertEqual(r["attempts"], 2)
        self.assertIn("Erro412", r["error"])

    def test_outra_falha_vira_erro_sem_excecao(self):
        cliente = ClienteFalso([manifesto(**{"2008-01-AC": parte()})])

        def put(c, etag, **kw):
            raise RuntimeError("AccessDenied")

        r = sync_check.write_check_marks(cliente, "k", self.MARCAS, put=put)
        self.assertEqual(r["written"], 0)
        self.assertEqual(r["attempts"], 1)
        self.assertIn("AccessDenied", r["error"])

    def test_sem_marcas_ou_sem_particao_aplicavel_nao_grava(self):
        cliente = ClienteFalso([manifesto(**{"2008-01-AC": parte(size=1)})])
        chamadas = []
        r = sync_check.write_check_marks(cliente, "k", {}, put=lambda *a, **k: chamadas.append(1))
        self.assertEqual(r["written"], 0)
        self.assertEqual(cliente.leituras, 0)
        r = sync_check.write_check_marks(cliente, "k", self.MARCAS, put=lambda *a, **k: chamadas.append(1))
        self.assertEqual(r, {"written": 0, "attempts": 1, "error": None})
        self.assertEqual(chamadas, [])


class ResumoAnuncia(unittest.TestCase):
    def test_summary_copia_e_anuncia_os_campos(self):
        m = manifesto(**{
            "2008-01-AC": parte(last_checked_at=QUANDO, check_method="size"),
            "2008-01-AL": parte(size=2),  # nunca conferida: campos ausentes, não null
        })
        s = manifest_summary.summarize(m, "sih/rd/manifest.json")
        self.assertIn("last_checked_at", s["summary"]["fields"])
        self.assertIn("check_method", s["summary"]["fields"])
        self.assertEqual(s["summary"]["version"], "1.1.0")
        self.assertEqual(s["partitions"]["2008-01-AC"]["last_checked_at"], QUANDO)
        self.assertEqual(s["partitions"]["2008-01-AC"]["check_method"], "size")
        self.assertNotIn("last_checked_at", s["partitions"]["2008-01-AL"])
        self.assertEqual(s["last_updated"], m["last_updated"])
        # O vigia do portfolio-monitor lê só o primeiro KB: o anúncio tem de caber lá.
        corpo = json.dumps(s, ensure_ascii=False, separators=(",", ":"))
        self.assertLess(corpo.index('"partitions"'), 1024)


if __name__ == "__main__":
    unittest.main(verbosity=2)
