#!/bin/bash

# Script para instalação do serviço EasiDataRelay

# 1. Validar se o script está sendo executado como sudo
if [ "$EUID" -ne 0 ]; then
    print_warning "Por favor, execute este script como root/sudo"
    exit 1
fi

# Cores para a saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função para imprimir saída colorida
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

# 2. Preparação do ambiente
cd /opt

# Verificar se a pasta já existe
if [ -d "easidatarelay" ]; then
    # Criar backup com data e hora atual
    backup_name="easidatarelay_backup_$(date +'%Y%m%d_%H%M%S')"
    print_warning "Pasta existente encontrada. Criando backup: $backup_name"
    mv easidatarelay "$backup_name"
fi

# 3. Download e extração
echo
echo ">>> Baixando easidatarelay..."
wget https://storage.easi.live/easicash/easidatarelay/easidatarelay-v1.1.3.zip

if [ ! -f "easidatarelay-v1.1.3.zip" ]; then
    print_error "Download falhou! Por favor, verifique sua conexão com a internet."
    exit 1
fi

echo ">>> Extraindo arquivos..."
unzip easidatarelay-v1.1.3.zip
rm easidatarelay-v1.1.3.zip

# 4. Integração com o banco de dados
echo
echo ">>> Lendo códigos POS do banco de dados..."

mysql_password='$easi$'

# Tenta novamente com senha
pos_codes=$(mysql -u easi -p"$mysql_password" -D easi -e "SELECT pos_code FROM tbl_cash_pos" -s --skip-column-names 2>/dev/null)

if [ $? -ne 0 ]; then
    print_error "Erro: Não foi possível conectar ao banco de dados com a senha fornecida."
    exit 1
fi

if [ -z "$pos_codes" ]; then
    print_error "Erro: Nenhum código POS encontrado no banco de dados."
    exit 1
fi

# Processar os dados - remover separadores, formatar para 6 dígitos com zeros à esquerda
pattern=""
first=true
while IFS= read -r code; do
    # Remover quaisquer caracteres não numéricos
    clean_code=$(echo "$code" | tr -d -c '0-9')
    
    # Formatando para 6 dígitos com zeros à esquerda (manipular valores vazios)
    if [ -n "$clean_code" ]; then
        formatted_code=$(printf "%06d" "$clean_code" 2>/dev/null)
        
        # Verificar se o printf foi bem-sucedido (número válido)
        if [ $? -eq 0 ]; then
            if [ "$first" = true ]; then
                pattern="$formatted_code"
                first=false
            else
                pattern="$pattern|$formatted_code"
            fi
        fi
    fi
done <<< "$pos_codes"

if [ -z "$pattern" ]; then
    print_error "Erro: Nenhum código POS válido encontrado após o processamento."
    exit 1
fi

echo
print_status "Padrão gerado: $pattern"
echo

# 5. Configuração do servidor
read -p "Este é o servidor principal? (yes/no): " is_main_server
read -p "Digite o IP do servidor principal: " server_ip
read -s -p "Digite a senha do servidor principal: " server_pass

echo
print_status "/n  IP do servidor: $server_ip"
print_status "  Senha do servidor: $server_pass"
echo

read -p "É topsistemas ou padrão? (1 para TopSistemas, 2 para Default): " server_type
echo

# Criar serviço pub apenas para servidor principal
if [[ "$is_main_server" == "yes" ]]; then
    cat > /etc/systemd/system/easidatarelaypub.service << EOF
[Unit]
Description=EASiBox Server Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=inwave
ExecStart=/opt/easidatarelay/easidatarelay --source-type UDP --source-ip 0.0.0.0 --source-port 23454 --target-type WEBSOCKET --target-ip $server_ip --target-port 23456 --target-password $server_pass
WorkingDirectory=/opt/easidatarelay

[Install]
WantedBy=multi-user.target
EOF
fi

# Criar serviço sub baseado no tipo (para servidor principal e clientes)
if [[ "$server_type" == "1" ]]; then
    cat > /etc/systemd/system/easidatarelaysub.service << EOF
[Unit]
Description=EASiBox Server Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=inwave
ExecStart=/opt/easidatarelay/easidatarelay --source-type WEBSOCKET --source-ip $server_ip --source-port 23456 --target-type UDP --target-ip 127.0.0.1 --target-port 23455 --source-password $server_pass --pattern "^($pattern)"
WorkingDirectory=/opt/easidatarelay

[Install]
WantedBy=multi-user.target
EOF
else
    cat > /etc/systemd/system/easidatarelaysub.service << EOF
[Unit]
Description=EASiBox Server Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
User=inwave
ExecStart=/opt/easidatarelay/easidatarelay --source-type WEBSOCKET --source-ip $server_ip --source-port 23456 --target-type UDP --target-ip 127.0.0.1 --target-port 23455 --source-password $server_pass --pattern "^.{8}($pattern)"
WorkingDirectory=/opt/easidatarelay

[Install]
WantedBy=multi-user.target
EOF
fi

# 6. Ativação e verificação
echo ">>> Habilitando e iniciando serviços..."
echo

if [[ "$is_main_server" == "yes" ]]; then
    systemctl enable easidatarelaypub.service
    systemctl start easidatarelaypub.service
    print_status "Status do serviço Pub:"
    systemctl status easidatarelaypub.service --no-pager -l
fi
echo

systemctl enable easidatarelaysub.service
systemctl start easidatarelaysub.service
print_status "Status do serviço Sub:"
systemctl status easidatarelaysub.service --no-pager -l
echo

print_status ">>> Instalação concluída!"
echo

if [[ "$is_main_server" == "yes" ]]; then
    echo "Serviços Pub e Sub foram configurados e iniciados."
else
    echo "Serviço Sub foi configurado e iniciado."
fi