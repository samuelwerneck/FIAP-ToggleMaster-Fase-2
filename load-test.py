#!/usr/bin/env python3
"""
Script de Geração de Carga para Demonstração de Escalabilidade (HPA)
Gera requisições concorrentes contra o Load Balancer do EKS.
"""
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ELB = "a838736d9238b479f8776c0008989e3e-f4c02bdf91ef1b9c.elb.us-east-1.amazonaws.com"
URL = f"http://{ELB}/evaluate?user_id=load-test-user&flag_name=aws-cloud-dashboard"

CONCURRENCY = 40       # Número de threads simultâneas
DURATION_SECONDS = 90  # Duração do teste em segundos

print("=" * 65)
print(f"🚀 INICIANDO TESTE DE CARGA NO TOGGLEMASTER (HPA)")
print(f"Destino: {URL}")
print(f"Concorrência: {CONCURRENCY} threads | Duração: {DURATION_SECONDS} segundos")
print("=" * 65)

total_requests = 0
total_success = 0
total_errors = 0
running = True

def send_request():
    global total_requests, total_success, total_errors
    while running:
        try:
            req = urllib.request.Request(URL)
            with urllib.request.urlopen(req, timeout=3) as resp:
                if resp.status == 200:
                    total_success += 1
                else:
                    total_errors += 1
        except Exception:
            total_errors += 1
        total_requests += 1

start_time = time.time()

with ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
    futures = [executor.submit(send_request) for _ in range(CONCURRENCY)]
    
    try:
        while time.time() - start_time < DURATION_SECONDS:
            elapsed = int(time.time() - start_time)
            rps = total_requests / max(1, elapsed)
            print(f"[{elapsed:02d}s / {DURATION_SECONDS}s] Enviadas: {total_requests} reqs | Sucesso: {total_success} | Erros: {total_errors} | ~{rps:.1f} req/s", end="\r")
            time.sleep(1)
    finally:
        running = False

elapsed = time.time() - start_time
print("\n" + "=" * 65)
print(f"🏁 TESTE CONCLUÍDO:")
print(f"Total de Requisições: {total_requests}")
print(f"Sucessos (HTTP 200):  {total_success}")
print(f"Erros:                {total_errors}")
print(f"Média:                {total_requests / elapsed:.1f} requisições/segundo")
print("=" * 65)
