#!/bin/bash

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS=$DISTRIB_ID
elif [ -f /etc/debian_version ]; then
    OS=Debian
fi

PASSWORD_DIR=/etc/perfsonar/elastic
PASSWORD_FILE=${PASSWORD_DIR}/auth_setup.out
ADMIN_LOGIN_FILE=${PASSWORD_DIR}/elastic_login
LOGSTASH_USER=pscheduler_logstash
ELASTIC_CONFIG_DIR=/etc/elasticsearch
ELASTIC_CONFIG_FILE=${ELASTIC_CONFIG_DIR}/elasticsearch.yml
OPENDISTRO_SECURITY_PLUGIN=/usr/share/elasticsearch/plugins/opendistro_security
OPENDISTRO_SECURITY_FILES=${OPENDISTRO_SECURITY_PLUGIN}/securityconfig
if [[ $OS == *"Debian"* ]]; then
    CACERTS_FILE=/usr/share/elasticsearch/jdk/lib/security/cacerts
    LOGSTASH_SYSCONFIG=/etc/default/logstash
else
    CACERTS_FILE=/etc/pki/java/cacerts
    LOGSTASH_SYSCONFIG=/etc/sysconfig/logstash
fi

# Certificates configurations
# Clear out any config old settings
sed -i '/^opendistro_security.ssl.transport.pemcert_filepath.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.ssl.transport.pemkey_filepath.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.ssl.http.pemcert_filepath.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.ssl.http.pemkey_filepath.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.authcz.admin_dn.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.allow_unsafe_democertificates.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^  - CN=kirk.*/d' $ELASTIC_CONFIG_FILE
# Clear out any security script settings
sed -i '/^  - CN=admin.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^opendistro_security.nodes_dn.*/d' $ELASTIC_CONFIG_FILE
sed -i '/^  - CN=localhost.*/d' $ELASTIC_CONFIG_FILE
# Delete demo certificate files
rm -f ${ELASTIC_CONFIG_DIR}/*.pem
# Generate Opendistro Certificates
# Root CA
openssl genrsa -out ${ELASTIC_CONFIG_DIR}/root-ca-key.pem 2048
openssl req -new -x509 -sha256 -key ${ELASTIC_CONFIG_DIR}/root-ca-key.pem -subj "/CN=localhost/OU=Example/O=Example/C=br" -out ${ELASTIC_CONFIG_DIR}/root-ca.pem -days 180
# Admin cert
openssl genrsa -out ${ELASTIC_CONFIG_DIR}/admin-key-temp.pem 2048
openssl pkcs8 -inform PEM -outform PEM -in ${ELASTIC_CONFIG_DIR}/admin-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out ${ELASTIC_CONFIG_DIR}/admin-key.pem
openssl req -new -key ${ELASTIC_CONFIG_DIR}/admin-key.pem -subj "/CN=admin" -out ${ELASTIC_CONFIG_DIR}/admin.csr
openssl x509 -req -in ${ELASTIC_CONFIG_DIR}/admin.csr -CA ${ELASTIC_CONFIG_DIR}/root-ca.pem -CAkey ${ELASTIC_CONFIG_DIR}/root-ca-key.pem -CAcreateserial -sha256 -out ${ELASTIC_CONFIG_DIR}/admin.pem -days 180
# Node cert
openssl genrsa -out ${ELASTIC_CONFIG_DIR}/node-key-temp.pem 2048
openssl pkcs8 -inform PEM -outform PEM -in ${ELASTIC_CONFIG_DIR}/node-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out ${ELASTIC_CONFIG_DIR}/node-key.pem
openssl req -new -key ${ELASTIC_CONFIG_DIR}/node-key.pem -subj "/CN=localhost/OU=node/O=node/L=test/C=br" -out ${ELASTIC_CONFIG_DIR}/node.csr
openssl x509 -req -in ${ELASTIC_CONFIG_DIR}/node.csr -CA ${ELASTIC_CONFIG_DIR}/root-ca.pem -CAkey ${ELASTIC_CONFIG_DIR}/root-ca-key.pem -CAcreateserial -sha256 -out ${ELASTIC_CONFIG_DIR}/node.pem -days 180
# Cleanup
rm -f ${ELASTIC_CONFIG_DIR}/admin-key-temp.pem ${ELASTIC_CONFIG_DIR}/admin.csr ${ELASTIC_CONFIG_DIR}/node-key-temp.pem ${ELASTIC_CONFIG_DIR}/node.csr
# Add to Java cacerts
openssl x509 -outform der -in ${ELASTIC_CONFIG_DIR}/node.pem -out ${ELASTIC_CONFIG_DIR}/node.der
keytool -import -alias node -keystore ${CACERTS_FILE} -file ${ELASTIC_CONFIG_DIR}/node.der -storepass changeit -noprompt

# Apply new settings
echo "opendistro_security.ssl.transport.pemcert_filepath: node.pem" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "opendistro_security.ssl.transport.pemkey_filepath: node-key.pem" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "opendistro_security.ssl.http.pemcert_filepath: node.pem" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "opendistro_security.ssl.http.pemkey_filepath: node-key.pem" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "opendistro_security.authcz.admin_dn:" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "  - CN=admin" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "opendistro_security.nodes_dn:" | tee -a $ELASTIC_CONFIG_FILE > /dev/null
echo "  - CN=localhost,OU=node,O=node,L=test,C=br" | tee -a $ELASTIC_CONFIG_FILE > /dev/null

# Generate default users random passwords, write them to tmp file and, if it works, move to permanent file
echo "[Generating elasticsearch passwords]"
if [ -e "$PASSWORD_FILE" ]; then
    echo "$PASSWORD_FILE already exists, so not generating new passwords"
else
    mkdir -p $PASSWORD_DIR
    TEMPFILE=$(mktemp)
    egrep -v '^[[:blank:]]' "${OPENDISTRO_SECURITY_FILES}/internal_users.yml" | egrep "\:$" | egrep -v '^\_' | sed 's\:\\g' | while read user; do
        PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
        echo "$user $PASS" >> $TEMPFILE
        HASHED_PASS=$(${OPENDISTRO_SECURITY_PLUGIN}/tools/hash.sh -p $PASS | sed -e 's/[&\\/]/\\&/g')
        sed -i -e '/^'$user'\:$/,/[^hash.*$]/      s/\(hash\: \).*$/\1"'$HASHED_PASS'"/' "${OPENDISTRO_SECURITY_FILES}/internal_users.yml"
    done
    mv $TEMPFILE $PASSWORD_FILE
    chmod 600 $PASSWORD_FILE
fi

# Get password for admin user
ADMIN_PASS=$(grep "admin " $PASSWORD_FILE | head -n 1 | sed 's/^admin //')
if [ $? -ne 0 ]; then
    echo "Failed to parse password"
    exit 1
elif [ -z "$ADMIN_PASS" ]; then
    echo "Unable to find admin password in $PASSWORD_FILE. Exiting."
    exit 1
fi

# Create file with admin login - delete if already exists
if [ -f "$ADMIN_LOGIN_FILE" ] ; then
    rm "$ADMIN_LOGIN_FILE"
fi
echo "admin $ADMIN_PASS" | tee -a $ADMIN_LOGIN_FILE > /dev/null
chmod 600 $ADMIN_LOGIN_FILE
echo "[DONE]"
echo ""

# new users: pscheduler_logstash, pscheduler_reader and pscheduler_writer
# 1. Create users, generate passwords and save them to file 
echo "[Creating $LOGSTASH_USER user]"
grep "# Pscheduler Logstash" $OPENDISTRO_SECURITY_FILES/internal_users.yml
if [ $? -eq 0 ]; then
    echo "User already created"
else
    # pscheduler_logstash
    PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    HASHED_PASS=$(${OPENDISTRO_SECURITY_PLUGIN}/tools/hash.sh -p $PASS)
    echo "$LOGSTASH_USER $PASS" | tee -a $PASSWORD_FILE  > /dev/null
    echo | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo 'pscheduler_logstash:' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  hash: "'$HASHED_PASS'"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  description: "pscheduler logstash user"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null

    # pscheduler_reader
    PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    HASHED_PASS=$(${OPENDISTRO_SECURITY_PLUGIN}/tools/hash.sh -p $PASS)
    echo "pscheduler_reader $PASS" | tee -a $PASSWORD_FILE  > /dev/null
    echo | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo 'pscheduler_reader:' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  hash: "'$HASHED_PASS'"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  description: "pscheduler reader user"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
 
    # pscheduler_writer
    PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    HASHED_PASS=$(${OPENDISTRO_SECURITY_PLUGIN}/tools/hash.sh -p $PASS)
    echo "pscheduler_writer $PASS" | tee -a $PASSWORD_FILE  > /dev/null
    echo | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo 'pscheduler_writer:' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  hash: "'$HASHED_PASS'"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null
    echo '  description: "pscheduler writer user"' | tee -a $OPENDISTRO_SECURITY_FILES/internal_users.yml > /dev/null

    # Enable anonymous user
    sed -i 's/anonymous_auth_enabled: false/anonymous_auth_enabled: true/g' $OPENDISTRO_SECURITY_FILES/config.yml
fi
echo "[DONE]"
echo ""

# 2. Create roles
echo "[Creating $LOGSTASH_USER role]"
grep "# Pscheduler Logstash" $OPENDISTRO_SECURITY_FILES/roles.yml
if [ $? -eq 0 ]; then
    echo "Role already created"
else
    # pscheduler_logstash
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "pscheduler_logstash:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  cluster_permissions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "    - 'cluster_monitor'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "    - 'cluster_manage_index_templates'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  index_permissions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "    - index_patterns:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'pscheduler_*'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      allowed_actions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'write'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'read'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'delete'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'create_index'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'manage'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'indices:admin/template/delete'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'indices:admin/template/get'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'indices:admin/template/put'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null

    # pscheduler_reader => read-only access to the pscheduler indices
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "pscheduler_reader:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  reserved: true" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  index_permissions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "    - index_patterns:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'pscheduler*'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      allowed_actions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'read'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null

    # pscheduler_writer => write-only access to the pscheduler indices
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "pscheduler_writer:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  reserved: true" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "  index_permissions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "    - index_patterns:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'pscheduler*'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      allowed_actions:" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
    echo "      - 'write'" | tee -a $OPENDISTRO_SECURITY_FILES/roles.yml > /dev/null
fi
echo "[DONE]"
echo ""

# 3. Map users to roles
echo "[Mapping $LOGSTASH_USER user to $LOGSTASH_USER role]"
grep "# Pscheduler Logstash" $OPENDISTRO_SECURITY_FILES/roles_mapping.yml
if [ $? -eq 0 ]; then
    echo "Map already created"
else
    # pscheduler_logstash
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo 'pscheduler_logstash:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  users:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  - "pscheduler_logstash"' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null

    # pscheduler_reader
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo 'pscheduler_reader:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  users:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  - "pscheduler_reader"' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    # maps pscheduler_reader role with the anonymous user backend role
    echo '  backend_roles:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  - "opendistro_security_anonymous_backendrole"' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null

    # pscheduler_writer
    echo | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo 'pscheduler_writer:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  reserved: true' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  users:' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
    echo '  - "pscheduler_writer"' | tee -a $OPENDISTRO_SECURITY_FILES/roles_mapping.yml > /dev/null
fi
echo "[DONE]"
echo ""

# 5. Configure logstash to use pscheduler_logstash user/password
echo "[Configure logstash]"
LOGSTASH_PASS=$(grep "pscheduler_logstash " $PASSWORD_FILE | head -n 1 | sed 's/^pscheduler_logstash //')
echo "LOGSTASH_ELASTIC_USER=${LOGSTASH_USER}" | tee -a $LOGSTASH_SYSCONFIG > /dev/null
sed -i 's/elastic_output_password=pscheduler_logstash/elastic_output_password='$LOGSTASH_PASS'/g' $LOGSTASH_SYSCONFIG
echo "[DONE]"
echo ""

# 6. Fixes
#changing the logstash port range to avoid conflict with opendistro-performance-analyzer
sed -i 's/# http.port: 9600-9700/http.port: 9601-9700/g' /etc/logstash/logstash.yml

#issue: https://github.com/opendistro-for-elasticsearch/performance-analyzer/issues/229
echo false | sudo tee /usr/share/elasticsearch/data/batch_metrics_enabled.conf
