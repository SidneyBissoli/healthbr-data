# ==============================================================================
# sih-ftp-breaker-test.R — Testes unitários do circuit breaker do FTP (SIH)
# ==============================================================================
#
# Extrai do pipeline apenas as funções puras (classificação de erro,
# contador de falhas, verificação de saúde) e as exercita com probes falsos —
# sem tocar rede, R2 ou disco. Roda em segundos:
#
#   Rscript scripts/pipeline/sih-ftp-breaker-test.R
#
# ==============================================================================

suppressPackageStartupMessages(library(glue))

# --- Extrair definições do pipeline sem executá-lo ----------------------------
exprs <- parse("scripts/pipeline/sih-pipeline-r.R")
alvo  <- c("classificar_erro_ftp", "registrar_resultado_ftp",
           "verificar_saude_ftp", ".ftp",
           "FTP_FALHAS_LIMIAR", "FTP_PROBE_TENTATIVAS", "FTP_PROBE_ESPERA_S",
           "EXIT_FTP_INDISPONIVEL")
for (e in exprs) {
  if (!(is.call(e) && identical(e[[1]], as.name("<-")))) next
  lhs <- e[[2]]
  # `nome <- ...` para os alvos, e também `.ftp$campo <- ...`
  if (is.name(lhs) && as.character(lhs) %in% alvo) {
    eval(e, envir = globalenv())
  } else if (is.call(lhs) && identical(lhs[[1]], as.name("$")) &&
             identical(lhs[[2]], as.name(".ftp"))) {
    eval(e, envir = globalenv())
  }
}
stopifnot(exists("verificar_saude_ftp"), exists(".ftp"))

# --- Harness mínimo -----------------------------------------------------------
n_ok <- 0; n_fail <- 0
check <- function(desc, cond) {
  if (isTRUE(cond)) { n_ok <<- n_ok + 1; cat("  ok   -", desc, "\n") }
  else              { n_fail <<- n_fail + 1; cat("  FAIL -", desc, "\n") }
}
reset <- function() {
  .ftp$falhas_seguidas <- 0L
  .ftp$indisponivel    <- FALSE
  .ftp$parou_em        <- NA_character_
}
sem_espera <- function(s) invisible(NULL)

cat("\n[classificar_erro_ftp]\n")
check("550 / 'does not exist' é missing",
      classificar_erro_ftp("Remote file not found [ftp.datasus.gov.br]: The file does not exist") == "missing")
check("'RETR failed: 550' é missing",
      classificar_erro_ftp("RETR command failed: 550 No such file") == "missing")
check("timeout de conexão é transient",
      classificar_erro_ftp("Timeout was reached [ftp.datasus.gov.br]: Failed to connect to ftp.datasus.gov.br port 21 after 60001 ms") == "transient")
check("connection reset é transient",
      classificar_erro_ftp("Recv failure: Connection reset by peer") == "transient")
check("empty download é transient",
      classificar_erro_ftp("empty download") == "transient")
check("mensagem com '550' dentro de outro número não confunde",
      classificar_erro_ftp("Transferred 15500 bytes then stalled") == "transient")

cat("\n[registrar_resultado_ftp]\n")
reset()
registrar_resultado_ftp(c("transient", "transient", "transient"))
check("3 transient acumulam 3", .ftp$falhas_seguidas == 3L)
registrar_resultado_ftp("missing")
check("'missing' (servidor respondeu) zera a sequência", .ftp$falhas_seguidas == 0L)
registrar_resultado_ftp(c("transient", "ok", "transient", "transient"))
check("'ok' zera e depois volta a contar", .ftp$falhas_seguidas == 2L)

cat("\n[verificar_saude_ftp] abaixo do limiar\n")
reset()
registrar_resultado_ftp(rep("transient", FTP_FALHAS_LIMIAR - 1L))
probes <- 0
check("segue sem sondar quando falhas < limiar",
      isTRUE(verificar_saude_ftp(probe = function() { probes <<- probes + 1; FALSE },
                                 esperar = sem_espera)) && probes == 0)

cat("\n[verificar_saude_ftp] limiar atingido, FTP volta na 2a sonda\n")
reset()
registrar_resultado_ftp(rep("transient", FTP_FALHAS_LIMIAR))
respostas <- c(FALSE, TRUE, TRUE); i <- 0
esperas <- 0
r <- verificar_saude_ftp(probe = function() { i <<- i + 1; respostas[i] },
                         esperar = function(s) esperas <<- esperas + 1)
check("retorna TRUE (FTP usável)", isTRUE(r))
check("sondou 2 vezes", i == 2)
check("esperou 1 vez entre sondas", esperas == 1)
check("zerou a sequência de falhas", .ftp$falhas_seguidas == 0L)
check("não marcou indisponível", !.ftp$indisponivel)

cat("\n[verificar_saude_ftp] limiar atingido, FTP nunca responde\n")
reset()
registrar_resultado_ftp(rep("transient", FTP_FALHAS_LIMIAR + 3L))
i <- 0; esperas <- 0
r <- verificar_saude_ftp(probe = function() { i <<- i + 1; FALSE },
                         esperar = function(s) esperas <<- esperas + 1)
check("retorna FALSE", isFALSE(r))
check(glue("sondou {FTP_PROBE_TENTATIVAS} vezes"), i == FTP_PROBE_TENTATIVAS)
check("esperou entre sondas (n-1 vezes)", esperas == FTP_PROBE_TENTATIVAS - 1)
check("marcou FTP indisponível", isTRUE(.ftp$indisponivel))
i <- 0
r2 <- verificar_saude_ftp(probe = function() { i <<- i + 1; TRUE }, esperar = sem_espera)
check("uma vez indisponível, não sonda de novo e segue FALSE", isFALSE(r2) && i == 0)

cat("\n[constantes]\n")
check("exit code de FTP indisponível é 75 (EX_TEMPFAIL)", EXIT_FTP_INDISPONIVEL == 75L)
check("limiar/probes/espera são inteiros positivos",
      all(c(FTP_FALHAS_LIMIAR, FTP_PROBE_TENTATIVAS, FTP_PROBE_ESPERA_S) > 0))

cat(glue("\n{n_ok} ok, {n_fail} falha(s)\n\n"))
if (n_fail > 0) quit(save = "no", status = 1)
