"""
Testes das listagens FTP do sync engine com o FTP do DATASUS fora do ar.

Em 2026-10-05 um timeout no LIST do PNI derrubou o sync-check inteiro: o
`except (ftplib.all_errors, OSError, TimeoutError)` aninhava uma tupla noutra e
levantava TypeError na primeira falha, em vez de cair no retry e devolver
success=False. O defeito só aparece quando o FTP falha, por isso estes testes
simulam a falha (sem rede, sem R2).

Rodar:  python scripts/sync/sync_check_ftp_test.py
"""

import ftplib
import os
import socket
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_check  # noqa: E402

LISTAGENS = (
    sync_check.ftp_list_pni,
    sync_check.ftp_list_sinasc,
    sync_check.ftp_list_sih,
)

# Falhas reais do FTP do DATASUS: timeout do canal de dados (o caso de
# 2026-10-05), conexão recusada e resposta de erro do protocolo FTP.
FALHAS = (
    TimeoutError("timed out"),
    ConnectionRefusedError("connection refused"),
    socket.timeout("timed out"),
    ftplib.error_temp("421 Service not available"),
    EOFError(),
)


class FtpForaDoAr(unittest.TestCase):
    def test_falha_vira_resultado_e_nao_excecao(self):
        for listar in LISTAGENS:
            for falha in FALHAS:
                with self.subTest(listagem=listar.__name__, falha=repr(falha)):
                    ftp = mock.MagicMock()
                    ftp.retrlines.side_effect = falha
                    with mock.patch.object(sync_check.ftplib, "FTP", return_value=ftp), \
                         mock.patch.object(sync_check.time, "sleep") as dormir:
                        resultado = listar()
                    self.assertFalse(resultado["success"])
                    self.assertEqual(resultado["files"], {})
                    self.assertTrue(resultado["error"])
                    # Tentou MAX_RETRIES vezes, com espera entre as tentativas.
                    self.assertGreaterEqual(ftp.retrlines.call_count, sync_check.MAX_RETRIES)
                    self.assertEqual(dormir.call_count, sync_check.MAX_RETRIES - 1)

    def test_recupera_na_segunda_tentativa(self):
        for listar in LISTAGENS:
            with self.subTest(listagem=listar.__name__):
                chamadas = []

                def retrlines(_cmd, callback):
                    chamadas.append(_cmd)
                    if len(chamadas) == 1:
                        raise TimeoutError("timed out")
                    callback("05-23-19  05:19PM  14843 ARQUIVO.DBC")

                ftp = mock.MagicMock()
                ftp.retrlines.side_effect = retrlines
                with mock.patch.object(sync_check.ftplib, "FTP", return_value=ftp), \
                     mock.patch.object(sync_check.time, "sleep"):
                    resultado = listar()
                self.assertTrue(resultado["success"])
                self.assertEqual(resultado["files"].get("ARQUIVO.DBC"), 14843)


if __name__ == "__main__":
    unittest.main(verbosity=2)
