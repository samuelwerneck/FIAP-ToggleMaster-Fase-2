# ToggleMaster - Fase 2 (Tech Challenge Pós Tech FIAP)

## 📌 Dificuldades Encontradas e Decisões Técnicas de Engenharia

Este documento consolida o registro detalhado de todas as dificuldades técnicas, divergências de especificação, incompatibilidades de código e decisões de arquitetura encontradas durante a conteinerização e execução local dos microsserviços do **ToggleMaster**. 

Este registro serve como subsídio direto para o relatório de entrega e para o vídeo demonstrativo da Fase 2.

---

### 1. Restrição de 2 Instâncias de PostgreSQL para 3 Microsserviços Relacionais

* **Contexto:** O roteiro do projeto (página 4 e 9 do PDF) determinou que o ambiente local deve subir exatamente **9 contêineres** (5 microsserviços + 4 bancos de dados: 2 instâncias PostgreSQL, 1 Redis e 1 DynamoDB Local). No entanto, o ecossistema fornecido conta com **3 serviços relacionais distintos**:
  * `auth-service` $\rightarrow$ banco `auth_db`
  * `flag-service` $\rightarrow$ banco `flags_db`
  * `targeting-service` $\rightarrow$ banco `targeting_db`
* **Impasse Técnico:** A imagem oficial do Docker `postgres:15-alpine` suporta apenas um único banco de dados configurado via variável de ambiente (`POSTGRES_DB`). Ela não possui suporte nativo para provisionar múltiplos bancos de dados em uma única instância apenas através de variáveis do `docker-compose.yml`.
* **Decisão & Solução Adotada:** 
  * A primeira instância PostgreSQL (`auth-db`) ficou dedicada ao `auth-service`.
  * Para a segunda instância (`app-db`), criada para atender simultaneamente ao `flag-service` e ao `targeting-service`, criamos o script [`docker/init-app-db.sh`](file:///home/swerneck/Projetos/FIAP-ToggleMaster-Fase-2/docker/init-app-db.sh).
  * O script foi montado no diretório `/docker-entrypoint-initdb.d/` do contêiner. Durante o primeiro boot da instância, ele executa os comandos `CREATE DATABASE flags_db;` e `CREATE DATABASE targeting_db;` e em seguida aplica os scripts de schema (`init.sql`) de cada microsserviço nas suas respectivas bases.
  * Essa solução respeitou rigorosamente o teto de 9 contêineres do enunciado sem exigir nenhuma instância extra de banco relacional.

---

### 2. Incompatibilidade entre Versões de Dependências Python (Flask 2.2.2 vs. Werkzeug 3.x)

* **Contexto:** Os três microsserviços em Python (`flag-service`, `targeting-service` e `analytics-service`) utilizavam um arquivo `requirements.txt` fornecido com a biblioteca `Flask==2.2.2`.
* **Impasse Técnico:** Ao construir as imagens Docker e iniciar os serviços sob o Gunicorn, os contêineres entravam em reinicialização contínua (*CrashLoop*) com a seguinte exceção:
  ```text
  ImportError: cannot import name 'url_quote' from 'werkzeug.urls'
  ```
  Isso ocorreu porque o `requirements.txt` original não travava a versão da biblioteca transitiva `Werkzeug`. O gerenciador `pip` baixava a versão mais recente (`Werkzeug 3.1.x`), que removeu a função legada `url_quote`, essencial para a versão antiga do Flask 2.2.2.
* **Decisão & Solução Adotada:** 
  * Para preservar 100% do código da aplicação dos professores sem alterar nenhuma linha dos arquivos `app.py`, fixamos a compatibilidade de dependência nos `requirements.txt`:
    ```text
    Flask==2.2.2
    Werkzeug>=2.2.2,<3.0.0
    ```
  * Isso restabeleceu a compatibilidade binária imediata com o Flask 2.2.2 e permitiu que todos os workers Gunicorn iniciassem normalmente.

---

### 3. Falhas e Erros de Compilação Pré-existentes nos Microsserviços em Go

* **Contexto:** Os microsserviços `auth-service` e `evaluation-service` foram desenvolvidos em Go 1.21. No processo de conteinerização com compilação multi-stage (`go build`), nos deparamos com erros fatais de compilação em código fornecido.
* **Impasses Técnicos Encontrados:**
  1. **Sintaxe Inválida no `go.mod` do `auth-service`:** O arquivo trazia a diretiva `github.com/jackc/pgx/v4/stdlib v4.18.3` dentro do bloco `require`. Em Go, `stdlib` é um subpacote interno do driver `pgx/v4`, e não um módulo independente. O compilador abortava a compilação com `version invalid: should be v0 or v1, not v4`.
  2. **Imports Não Utilizados no Go:** O compilador do Go é estrito e proíbe imports não utilizados (*imported and not used* é considerado erro fatal pelo compilador, não mero warning):
     * Em `auth-service/key.go`: import `"fmt"` não utilizado.
     * Em `auth-service/handlers.go`: imports `"crypto/sha256"` e `"encoding/hex"` não utilizados.
     * Em `auth-service/main.go`: import `"fmt"` não utilizado, e o driver PostgreSQL estava importado como identificador nomeado em vez de *blank identifier* (`_ "github.com/jackc/pgx/v4/stdlib"`), que é o padrão da linguagem para registro estático de drivers de banco SQL.
     * Em `evaluation-service/evaluator.go`: import `"context"` não utilizado, enquanto faltava o import essencial `"os"` para chamar `os.Getenv("SERVICE_API_KEY")`.
* **Decisão & Solução Adotada:** 
  * Ajustamos cirurgicamente o `go.mod` removendo a entrada incorreta do subpacote.
  * Realizamos a limpeza dos imports não utilizados e adicionamos o import de `os` faltante.
  * Com isso, o build multi-stage estático compilou binários enxutos com sucesso e gerou imagens finais de apenas ~28 MB baseadas em Alpine Linux.

---

### 4. DynamoDB Local vs. AWS DynamoDB: Paridade de Ambientes e Idempotência

* **Contexto:** Houve uma aparente divergência de documentação no desafio:
  * O **PDF (página 4)** exige que o ambiente local execute um contêiner **DynamoDB Local** (`amazon/dynamodb-local`).
  * Já o **código-fonte e README do `analytics-service`** foram estruturados originalmente para conectar direto no DynamoDB da AWS via Boto3, sem aceitar parâmetro de endpoint customizado.
  * Além disso, a imagem oficial `amazon/dynamodb-local` inicia completamente limpa (sem nenhuma tabela provisionada).
* **Premissa Arquitetural:** O código da aplicação deveria seguir o princípio de **paridade de ambientes (*12-Factor App*)**: ter **uma única base de código** capaz de rodar tanto no ambiente de desenvolvimento local (Raspberry Pi / PC) quanto em produção na AWS (EKS), sem exigir alterações no código na hora da migração para a nuvem.
* **Decisão & Solução Adotada:**
  1. **Configuração via Variável de Ambiente:** Incluímos a leitura de `DYNAMODB_ENDPOINT_URL = os.getenv("DYNAMODB_ENDPOINT_URL")` no `analytics-service/app.py`. Se definida (local), o cliente Boto3 direciona as chamadas para `http://dynamodb-local:8000`; se ausente/vazia (nuvem), o Boto3 conecta automaticamente no endpoint nativo da AWS.
  2. **Criação Idempotente da Tabela (`ensure_dynamodb_table`):** Implementamos uma rotina no arranque do `analytics-service` que consulta a existência da tabela (`describe_table`). Se ela não existir (`ResourceNotFoundException`), a tabela `ToggleMasterAnalytics` é criada com a Partition Key `event_id`. Se a tabela já existir, a aplicação apenas segue a execução. Isso garantiu **idempotência total**: o Docker Compose pode ser iniciado e reiniciado infinitas vezes sem nunca falhar por conflito de tabela.

---

### 5. Cadeia de Autenticação Inter-serviços (M2M) e Resolução de Erros 401

* **Contexto:** Durante os testes ponta a ponta do hot path no `evaluation-service` (`/evaluate`), as requisições falhavam com `StatusBadGateway: flag-service retornou status 401`.
* **Impasse Técnico:** Os serviços `flag-service` e `targeting-service` possuem middlewares de autenticação estrita (`@require_auth`) que validam tokens contra o `auth-service`. Quando o `evaluation-service` consulta esses serviços internamente para resolver a decisão de uma flag, ele precisa se autenticar como um cliente válido.
* **Decisão & Solução Adotada:**
  * Compreendemos a dinâmica entre as duas chaves arquiteturais do sistema:
    * `MASTER_KEY`: chave administrativa usada exclusivamente para criar novas credenciais via `POST /admin/keys` no `auth-service`.
    * `SERVICE_API_KEY`: token de serviço gerado no `auth-service` e injetado via variável de ambiente no `evaluation-service`.
  * Configuramos a `SERVICE_API_KEY` gerada no arquivo `.env`. Com isso, as chamadas internas passaram a ser autorizadas com sucesso com retorno HTTP 200 e avaliação com cache no Redis.

---

### 6. Execução Multi-plataforma e Compatibilidade com ARM64 (Raspberry Pi 5)

* **Contexto:** Foi definida a meta de executar o projeto completo em um hardware de homelab dedicado: o **Raspberry Pi 5**.
* **Impasse Técnico:** O Raspberry Pi opera sobre arquitetura **ARM64 (aarch64)**, enquanto o ambiente comum de desenvolvimento utiliza **x86_64 (AMD64)**. Havia o risco de imagens oficiais ou dependências binárias em C (como `psycopg2` ou o binário do DynamoDB Local) não possuírem suporte nativo para ARM64, forçando emulação pesada.
* **Decisão & Solução Adotada:**
  * Analisamos os manifestos OCI de todas as imagens base utilizadas (`golang:1.21-alpine`, `alpine:3.19`, `python:3.10-slim`, `postgres:15-alpine`, `redis:7-alpine` e `amazon/dynamodb-local:latest`) e confirmamos suporte oficial multi-arquitetura nativo para `linux/arm64`.
  * A compilação em Go gera binários estáticos diretamente para a arquitetura alvo.
  * O consumo total de memória medido de todos os 9 contêineres somados ficou em torno de ~800 MB de RAM, garantindo que o Raspberry Pi 5 execute todo o ecossistema com folga de recursos.

---

### 7. Integração Híbrida Local com Fila AWS SQS Real

* **Contexto:** O projeto previa o uso de mensageria assíncrona entre o `evaluation-service` (produtor de eventos de telemetria) e o `analytics-service` (consumidor).
* **Impasse Técnico:** O roteiro do Tech Challenge não inclui um emulador de mensageria SQS local (como LocalStack) no escopo dos 4 bancos locais, exigindo o uso de uma fila real na AWS mesmo durante os testes locais.
* **Decisão & Solução Adotada:**
  * Provisionamos a fila Standard `togglemaster-events` no console da AWS na região `us-east-1`.
  * Mapeamos as credenciais temporárias do AWS Academy (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) e a `AWS_SQS_URL` no arquivo centralizado `.env`.
  * O teste funcional confirmou o ciclo completo: o `evaluation-service` publica eventos de avaliação na AWS SQS via internet, e o worker em background do `analytics-service` consome as mensagens da AWS em tempo real e persiste os dados no DynamoDB Local.

---

### 8. Autenticação SCRAM no PostgreSQL 15 vs. Libpq em ARM64 (`psycopg2-binary`)

* **Contexto:** Ao executar os microsserviços Python (`flag-service` e `targeting-service`) no Raspberry Pi 5 (ARM64), os processos falhavam continuamente na inicialização com a mensagem:
  ```text
  CRITICAL:app:Erro fatal ao conectar ao PostgreSQL: SCRAM authentication requires libpq version 10 or above
  ```
* **Impasse Técnico:** O PostgreSQL 15 adota `SCRAM-SHA-256` por padrão para autenticação segura de senhas. A versão antiga `psycopg2-binary==2.9.5` fornecida utilizava uma compilação de binários para Linux ARM64 vinculada a uma biblioteca C `libpq` desatualizada (< versão 10), incompatível com o algoritmo SCRAM.
* **Decisão & Solução Adotada:**
  * Atualizamos a dependência nos arquivos `requirements.txt` do `flag-service` e `targeting-service` para `psycopg2-binary>=2.9.9` (que empacota a `libpq 16` moderna com suporte nativo total a SCRAM em ARM64).
  * Incluímos o pacote de runtime `libpq5` nos respectivos `Dockerfile`s.
  * Essa correção é vital tanto para o Raspberry Pi 5 quanto para a futura implantação em produção na nuvem com o AWS RDS PostgreSQL.

---

## 🚀 FASE 2: Infraestrutura Cloud e Publicação no AWS ECR

Esta seção documenta a transição do ambiente local conteinerizado para a nuvem da AWS, cobrindo as decisões de arquitetura, configuração do ambiente CLI, criação de banco NoSQL e o processo de build e publicação dos microsserviços no **AWS Elastic Container Registry (ECR)**.

---

### 1. Decisão Técnica: Automação via AWS CLI vs. Console Web

* **Contexto:** A criação manual de múltiplos repositórios e serviços via interface web (Console AWS) é propensa a erros de digitação, exige navegação excessiva de telas e não é reprodutível. Além disso, a futura conexão do `kubectl` com o cluster EKS exigirá o AWS CLI nativo na máquina de desenvolvimento.
* **Decisão & Benefícios:**
  * Adotamos o **AWS CLI v2** instalado diretamente no host Linux para automatizar todo o provisionamento de recursos serverless e a autenticação do Docker.
  * O CLI consome as APIs públicas da AWS de forma idêntica ao console, permitindo criar múltiplos repositórios e validar o status de recursos com laços de repetição em segundos.

**Instalação do AWS CLI v2:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install
aws --version
```

---

### 2. Autenticação com Credenciais do AWS Academy Learner Lab

* **Contexto:** No ambiente do AWS Academy, o identificador de conta (`Account ID`) permanece fixo durante todo o curso, enquanto as credenciais de sessão expiram periodicamente (a cada 4 horas).
* **Solução:** Centralizamos as credenciais no arquivo `.env` e as exportamos para a sessão do terminal de trabalho antes de qualquer operação:

```bash
# Carregar credenciais do .env
set -a
source .env
set +a

# Validar identidade e permissões da sessão (LabRole)
aws sts get-caller-identity
```

---

### 3. Provisionamento do DynamoDB na AWS (`ToggleMasterAnalytics`)

* **Contexto:** O `analytics-service` consome eventos de telemetria da fila SQS e persiste o histórico em uma tabela NoSQL DynamoDB.
* **Decisão & Otimização de Custos:**
  * Provisionamos a tabela explicitamente na região `us-east-1` utilizando a chave de partição `event_id` (tipo String `S`).
  * Configuramos a cobrança como **`PAY_PER_REQUEST` (On-Demand)**. Essa escolha é essencial para o laboratório do Academy, pois zera custos fixos de capacidade provisionada (RCU/WCU) e preserva o teto de orçamento ($100).

```bash
# Criação da tabela
aws dynamodb create-table \
    --table-name ToggleMasterAnalytics \
    --attribute-definitions AttributeName=event_id,AttributeType=S \
    --key-schema AttributeName=event_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region us-east-1

# Verificação do status (deve retornar "ACTIVE")
aws dynamodb describe-table --table-name ToggleMasterAnalytics --query "Table.TableStatus"
```

---

### 4. Criação dos Repositórios no AWS ECR

* **Contexto:** O cluster Kubernetes (EKS) precisará baixar as imagens de contêiner de um registro privado e seguro dentro da própria conta da AWS.
* **Solução:** Criamos 5 repositórios dedicados no ECR (um para cada microsserviço) via laço no terminal:

```bash
# Criar os 5 repositórios no ECR
for repo in auth-service flag-service targeting-service evaluation-service analytics-service; do
  aws ecr create-repository --repository-name $repo --region us-east-1
done

# Listar e validar a criação dos repositórios
aws ecr describe-repositories --query "repositories[].repositoryName" --output table
```

---

### 5. Autenticação do Docker Daemon no Registro Privado ECR

* **Contexto:** Por motivos de segurança, o daemon do Docker local precisa de um token de autorização temporário emitido pelo IAM da AWS para conseguir enviar imagens para o ECR.
* **Solução:** Obtivemos o token de autenticação via AWS CLI e direcionamos diretamente para o `docker login`:

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
```

---

### 6. Compilação Limpa (x86_64) e Envio das Imagens (`docker push`)

* **Atenção à Paridade de Arquitetura (ARM64 vs. x86_64):**
  * Enquanto nosso ambiente de testes locais utilizou o **Raspberry Pi 5 (ARM64)**, os nós de trabalho padrão do Kubernetes no AWS EKS (como instâncias `t3.medium`) utilizam arquitetura **x86_64 (amd64)**.
  * O envio de imagens compiladas exclusivamente para ARM64 provocaria falhas fatais (`exec format error` / `CrashLoopBackOff`) nos pods do EKS.
  * Por isso, a compilação final e o envio foram executados no computador x86_64, garantindo imagens 100% nativas para o cluster em nuvem.
* **Processo Layer-by-Layer:**
  * O Docker envia cada camada separadamente, aproveitando o cache de imagens base idênticas (`Layer already exists`), otimizando o tráfego de rede e o armazenamento no ECR.

```bash
# 1. Limpeza de builds locais antigos
docker rmi -f $(docker images "*togglemaster*" -q) 2>/dev/null || true

# 2. Definição do registro oficial
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# 3. Build dos 5 microsserviços já com as tags do ECR
docker build -t ${REGISTRY}/auth-service:latest ./auth-service-main
docker build -t ${REGISTRY}/flag-service:latest ./flag-service-main
docker build -t ${REGISTRY}/targeting-service:latest ./targeting-service-main
docker build -t ${REGISTRY}/evaluation-service:latest ./evaluation-service-main
docker build -t ${REGISTRY}/analytics-service:latest ./analytics-service-main

# 4. Upload das imagens para o AWS ECR
for repo in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo "--- Enviando $repo para a AWS ---"
  docker push ${REGISTRY}/${repo}:latest
done

# 5. Verificação das tags enviadas no ECR (todas devem exibir 'latest')
for repo in auth-service flag-service targeting-service evaluation-service analytics-service; do
  echo "--- Imagens no ECR: $repo ---"
  aws ecr list-images --repository-name $repo --query "imageIds[*].imageTag" --output text
done
```

---

## 🚀 FASE 3: Orquestração no Kubernetes (AWS EKS), Bancos Gerenciados e Deploy E2E

Esta seção documenta a conclusão integral da Fase 2 do Tech Challenge: o provisionamento do cluster Kubernetes na AWS (**EKS**), instâncias relacionais (**RDS PostgreSQL**), cache em memória (**ElastiCache Redis**), ingress controller com **AWS Load Balancer**, auto-escalabilidade com **HPA**, resolução dos impasses técnicos de conectividade e validação ponta a ponta.

---

### 1. Resumo da Arquitetura Implantada

* **Plano de Controle Kubernetes:** 1 Cluster AWS EKS (`togglemaster-cluster`) com versão estável do Kubernetes (1.36), endpoint público/privado e utilizando a `LabRole`.
* **Nós de Computação (Worker Nodes):** 1 Managed Node Group (`togglemaster-nodes`) composto por instâncias EC2 `t3.medium`, escalabilidade configurada (Mínimo=1, Desejado=2, Máximo=4) e perfil de nó vinculado à `LabRole`.
* **Bancos Relacionais Gerenciados (RDS):** 3 instâncias independentes de PostgreSQL (`auth-db`, `flag-db`, `targeting-db`) em instâncias econômicas `db.t3.micro` alocadas no `togglemaster-db-subnet-group`.
* **Cache em Memória (ElastiCache):** 1 cluster Redis (`evaluation-redis`) com nó `cache.t3.micro` alocado no `togglemaster-redis-subnet-group`.
* **Balanceamento e Roteamento Externo:** **Nginx Ingress Controller** implantado, provisionando automaticamente um **Application Load Balancer (ELB)** público na AWS.
* **Métricas e Escalabilidade:** **Metrics Server** implantado e **HorizontalPodAutoscaler (HPA)** configurado para autoscaling automático baseado em CPU (>70%) para os microsserviços.

---

### 2. Dificuldades Técnicas Encontradas e Soluções Adotadas

Durante a implantação na nuvem, nos deparamos com 6 desafios práticos de engenharia e conectividade distribuída, todos solucionados exclusivamente em nível de infraestrutura e variáveis de ambiente, sem alterar o código-fonte das aplicações:

#### Desafio 1: Incompatibilidade do "EKS Auto Mode" com a `LabRole` no AWS Academy
* **Problema:** Ao iniciar a criação do cluster EKS no Console da AWS, a interface sugeriu por padrão a ativação do novo "EKS Auto Mode". No entanto, o console disparou alertas de permissão ausente (`AmazonEKSComputePolicy`, `sts:TagSession`), bloqueando o avanço.
* **Causa Raiz:** O Modo Automático exige políticas gerenciadas modernas que a `LabRole` da conta acadêmica não possui e o estudante não tem privilégios de IAM para anexar.
* **Solução:** Desabilitamos manualmente o EKS Auto Mode, selecionando a configuração padrão do cluster com **Managed Node Group**, conforme orientado nas diretrizes da Opção A do roteiro.

#### Desafio 2: Esquemas de Banco Ausentes nas Novas Instâncias AWS RDS
* **Problema:** Ao provisionar as instâncias RDS PostgreSQL gerenciadas, os bancos nascem limpos e sem nenhuma tabela criada. Diferente do ambiente Docker Compose local (onde o script `init-app-db.sh` executava no volume de inicialização), os microsserviços no EKS falhavam ao buscar as tabelas `api_keys`, `flags` e `targeting_rules`.
* **Solução:** Criamos um manifesto declarativo de Job do Kubernetes (`k8s/02b-init-rds-job.yaml`) com a imagem `postgres:15-alpine`. Esse Job rodou um pod efêmero dentro do cluster, conectou nas 3 instâncias RDS via rede interna e aplicou com sucesso todos os comandos DDL (`CREATE TABLE`, funções e *triggers* de atualização temporal).

#### Desafio 3: Bloqueio de Tráfego entre Security Groups da VPC (EKS $\rightarrow$ RDS)
* **Problema:** O Job de inicialização e os pods dos serviços sofriam *timeout* contínuo tentando se conectar aos endpoints do RDS e do ElastiCache.
* **Causa Raiz:** O assistente de criação do EKS criou um Security Group exclusivo para os nós de computação (`eks-cluster-sg-...`), enquanto os bancos RDS foram associados ao grupo padrão `default` (`sg-005a...`). O grupo de segurança do banco não permitia conexões de entrada originadas do grupo de nós do Kubernetes.
* **Solução:** Autorizamos uma regra de *ingress* no Security Group padrão permitindo o tráfego interno da faixa CIDR da VPC (`172.31.0.0/16`):
  ```bash
  aws ec2 authorize-security-group-ingress --group-id sg-005a0c0734a7bc794 --protocol all --cidr 172.31.0.0/16 --region us-east-1
  ```
  Isso liberou a comunicação imediata em todas as portas internas (5432 para Postgres e 6379 para Redis).

#### Desafio 4: Rejeição de Conexão Não-Criptografada no RDS PostgreSQL (`auth-service`)
* **Problema:** O pod do `auth-service` (Go) entrou em *CrashLoopBackOff* com a mensagem:
  ```text
  FATAL: no pg_hba.conf entry for host "...", user "auth_user", database "auth_db", no encryption (SQLSTATE 28000)
  ```
* **Causa Raiz:** A string de conexão herdada do ambiente local utilizava o parâmetro `?sslmode=disable`. O AWS RDS PostgreSQL impõe por padrão conexões com criptografia TLS/SSL ativa.
* **Solução:** Alteramos a variável de ambiente para `?sslmode=require` e regeneramos as Secrets do Kubernetes em Base64. A conexão foi estabelecida com sucesso.

#### Desafio 5: Validação Estrita do Esquema de URL do Redis no Go (`evaluation-service`)
* **Problema:** O `evaluation-service` falhou na inicialização com a mensagem:
  ```text
  Não foi possível parsear a URL do Redis: redis: invalid URL scheme: evaluation-redis...
  ```
* **Causa Raiz:** O cliente Go `go-redis` (`redis.ParseURL`) exige que a string de conexão inclua expressamente o protocolo `redis://`. O endpoint fornecido pelo ElastiCache não inclui o prefixo por padrão.
* **Solução:** Ajustamos a variável de ambiente no `.env` para `redis://evaluation-redis.uepywj.0001.use1.cache.amazonaws.com:6379` e reiniciamos o deployment.

#### Desafio 6: Renovação da Chave de Serviço M2M na Nuvem
* **Problema:** As chaves de API do ambiente local não existiam no novo banco `auth_db` do RDS, impedindo o `evaluation-service` de autenticar chamadas internas para o `flag-service` e `targeting-service`.
* **Solução:** Através do Load Balancer público, realizamos a chamada administrativa `POST /admin/keys` utilizando a `MASTER_KEY`, geramos a nova credencial oficial em nuvem, injetamos seu valor na secret `SERVICE_API_KEY` e reiniciamos os pods via `kubectl rollout restart`.

---

### 3. Comandos Executados na Fase 3

#### A. Conexão do `kubectl` e Instalação dos Componentes de Cluster:
```bash
# Conectar kubectl ao cluster EKS
aws eks update-kubeconfig --region us-east-1 --name togglemaster-cluster

# Instalar Metrics Server (necessário para o HPA)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Instalar Nginx Ingress Controller (provisiona o Load Balancer da AWS)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/aws/deploy.yaml
```

#### B. Provisionamento dos Bancos RDS e ElastiCache Redis:
```bash
# 1. Criação dos Subnet Groups
aws rds create-db-subnet-group --db-subnet-group-name togglemaster-db-subnet-group --db-subnet-group-description "ToggleMaster DB Subnets" --subnet-ids subnet-0f5ecab058cb97af3 subnet-05c690bfb6ce9085b subnet-069e094bec232be6b --region us-east-1
aws elasticache create-cache-subnet-group --cache-subnet-group-name togglemaster-redis-subnet-group --cache-subnet-group-description "ToggleMaster Redis Subnets" --subnet-ids subnet-0f5ecab058cb97af3 subnet-05c690bfb6ce9085b subnet-069e094bec232be6b --region us-east-1

# 2. Criação das instâncias RDS PostgreSQL
aws rds create-db-instance --db-instance-identifier auth-db --db-instance-class db.t3.micro --engine postgres --master-username auth_user --master-user-password "togglemasterpass123" --db-name auth_db --allocated-storage 20 --db-subnet-group-name togglemaster-db-subnet-group --vpc-security-group-ids sg-005a0c0734a7bc794 --backup-retention-period 0 --no-multi-az --region us-east-1
aws rds create-db-instance --db-instance-identifier flag-db --db-instance-class db.t3.micro --engine postgres --master-username flag_user --master-user-password "togglemasterpass123" --db-name flags_db --allocated-storage 20 --db-subnet-group-name togglemaster-db-subnet-group --vpc-security-group-ids sg-005a0c0734a7bc794 --backup-retention-period 0 --no-multi-az --region us-east-1
aws rds create-db-instance --db-instance-identifier targeting-db --db-instance-class db.t3.micro --engine postgres --master-username targeting_user --master-user-password "togglemasterpass123" --db-name targeting_db --allocated-storage 20 --db-subnet-group-name togglemaster-db-subnet-group --vpc-security-group-ids sg-005a0c0734a7bc794 --backup-retention-period 0 --no-multi-az --region us-east-1

# 3. Criação do cluster ElastiCache Redis
aws elasticache create-cache-cluster --cache-cluster-id evaluation-redis --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 --cache-subnet-group-name togglemaster-redis-subnet-group --security-group-ids sg-005a0c0734a7bc794 --region us-east-1

# 4. Liberação de Ingress no Security Group da VPC
aws ec2 authorize-security-group-ingress --group-id sg-005a0c0734a7bc794 --protocol all --cidr 172.31.0.0/16 --region us-east-1
```

#### C. Aplicação Declarativa dos Manifestos Kubernetes (`k8s/`):
```bash
# 1. Namespace, ConfigMap e Secrets Base64
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-configmap.yaml
bash k8s/update-secrets.sh
kubectl apply -f k8s/02-secrets.yaml

# 2. Inicialização dos esquemas nos bancos RDS
kubectl apply -f k8s/02b-init-rds-job.yaml

# 3. Deployments e Services dos 5 Microsserviços
kubectl apply -f k8s/03-auth-service.yaml
kubectl apply -f k8s/04-flag-service.yaml
kubectl apply -f k8s/05-targeting-service.yaml
kubectl apply -f k8s/06-evaluation-service.yaml
kubectl apply -f k8s/07-analytics-service.yaml

# 4. Ingress e Autoscaler (HPA)
kubectl apply -f k8s/08-ingress.yaml
kubectl apply -f k8s/09-hpa.yaml
```

#### D. Validação Ponta a Ponta via Load Balancer da AWS:
```bash
# Obter o endpoint público do Load Balancer
ELB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# 1. Gerar Chave Administrativa
curl -s -X POST "http://${ELB}/admin/keys" \
  -H "Authorization: Bearer admin-secreto-123" \
  -H "Content-Type: application/json" \
  -d '{"name": "production-key"}'

# 2. Criar Feature Flag
curl -s -X POST "http://${ELB}/flags" \
  -H "Authorization: Bearer <SUA_CHAVE_API>" \
  -H "Content-Type: application/json" \
  -d '{"name": "aws-cloud-dashboard", "description": "Dashboard EKS", "is_enabled": true}'

# 3. Avaliar Feature Flag (Hot Path com Cache Redis e Disparo SQS)
curl -s "http://${ELB}/evaluate?user_id=meu-usuario-teste&flag_name=aws-cloud-dashboard"

# 4. Confirmar persistência no DynamoDB da AWS
aws dynamodb scan --table-name ToggleMasterAnalytics --region us-east-1 --query "Items[*].{User:user_id.S, Flag:flag_name.S, Result:result.BOOL, Time:timestamp.S}" --output table
```



