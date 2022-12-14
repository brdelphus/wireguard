    #!/bin/bash

    OS_DETECTED="$(awk '/^ID=/' /etc/*-release | awk -F'=' '{ print tolower($2) }')"
    CONTINUE_ON_UNDETECTED_OS=false                                                                                         
    WGUI_LINK="https://github.com/ngoduykhanh/wireguard-ui/releases/download/v0.3.7/wireguard-ui-v0.3.7-linux-amd64.tar.gz" 
    WGUI_PATH="/opt/wgui"                                                                                                   
    WGUI_BIN_PATH="/usr/local/bin"                                                                                          
    SYSTEMCTL_PATH="/usr/bin/systemctl"
    SYS_INTERFACE=$(ip route show default | awk '/default/ {print $5}')
    PUBLIC_IP="$(curl -s icanhazip.com)"
    STRICT_FIREWALL="n"
    SSH_PORT="22"
    WG_INTERFACE="wg0"
    WG_NETWORK="10.252.1.0/24"
    WG_PORT="51820"
    ENDPOINT=$PUBLIC_IP

    
    PASS="$1"
    function main() {

      install
      network_conf
      firewall_conf
      wg_conf
      wgui_conf

    }

    function install() {

      # Wireguard is not available in Buster, so take it from backports (only if Debian Buster has been detected in detect_os)
      if [ ! -z  "$BACKPORTS_REPO" ]; then
        if ! grep -q "^$BACKPORTS_REPO" /etc/apt/sources.list /etc/apt/sources.list.d/* > /dev/null 2>&1 ; then
          echo ""
          msg info "Enable Backports for Debian Buster"
          echo $BACKPORTS_REPO >> /etc/apt/sources.list
        fi
      fi

      echo ""
      echo "### Update & Upgrade"
      apt -qq update

      echo ""
      echo "### Installing WireGuard"
      apt -qq install wireguard -y

      echo ""
      echo "### Installing pkgs needed"
      apt -qq install apache2 libapache2-mod-proxy-uwsgi certbot pwgen -y

      echo ""
      echo "### Installing Wireguard-UI"
      if [ ! -d $WGUI_PATH ]; then
        mkdir -m 077 $WGUI_PATH
      fi

      wget -qO - $WGUI_LINK | tar xzf - -C $WGUI_PATH

      if [ -f $WGUI_BIN_PATH/wireguard-ui ]; then
        rm $WGUI_BIN_PATH/wireguard-ui
      fi
      ln -s $WGUI_PATH/wireguard-ui $WGUI_BIN_PATH/wireguard-ui
 
      cd /tmp
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
      unzip awscliv2.zip
      cd aws && sudo ./install
      cd -
      
      systemctl stop apache2
      a2enmod ssl
      a2enmod proxy
      a2enmod proxy_http
      a2enmod proxy_balancer
      a2enmod headers
      a2enmod rewrite
      a2ensite default-ssl
      
      echo "RewriteEngine On 
      RewriteCond %{HTTPS}  !=on 
      RewriteRule ^/?(.*) https://%{SERVER_NAME}/$1 [R,L]" > /var/www/html/.htaccess
      
      echo "<VirtualHost *:443 >
      ServerName vpn.dev.myvlc.com
      DocumentRoot /var/www/html
      <IfModule mod_ssl.c>
         SSLEngine On    
         SSLCertificateChainFile \"/etc/letsencrypt/live/vpn.dev.myvcl.com/fullchain.pem\"
         SSLCertificateFile      \"/etc/letsencrypt/live/vpn.dev.myvcl.com/cert.pem\"
         SSLCertificateKeyFile   \"/etc/letsencrypt/live/vpn.dev.myvcl.com/privkey.pem\"
         SSLOptions +StrictRequire +StdEnvVars -ExportCertData
         SSLProtocol -all +TLSv1.2 +TLSv1.3
         SSLHonorCipherOrder On
         SSLCipherSuite SSL ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384
         SSLCipherSuite TLSv1.3 TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384
         SSLOpenSSLConfCmd ECDHParameters secp384r1
         SSLOpenSSLConfCmd Curves sect571r1:sect571k1:secp521r1:sect409k1:sect409r1:secp384r1:sect283k1:sect283r1:secp256k1:prime256v1
      <FilesMatch \"\.(cgi|shtml|phtml|php)$i\">
         SSLOptions +StdEnvVars
      </FilesMatch>
      BrowserMatch \"MSIE [2-6]\" nokeepalive ssl-unclean-shutdown downgrade-1.0 force-response-1.0
        # MSIE 7 and newer should be able to use keepalive
        BrowserMatch \"MSIE [17-9]\" ssl-unclean-shutdown
      </IfModule>
      <IfModule mod_security2.c>
        SecRuleEngine Off
      </IfModule>  
        ErrorLog /var/log/apache2/vpn-error.log
        CustomLog /var/log/apache2/vpn-access.log combined
      <IfModule mod_proxy.c>
        SSLProxyEngine On
        RequestHeader set X-Forwarded-Proto \"https\"
        ProxyPreserveHost On
        ProxyPass / http://localhost:5000/
        ProxyPassReverse / http://localhost:5000/
      </IfModule>
      <location / >
      </location>
      </VirtualHost>" > /etc/apache2/sites-enabled/default-ssl.conf
            
      echo "<VirtualHost *:80>
        Redirect / https://vpn.dev.myvcl.com
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/html
        ErrorLog ${APACHE_LOG_DIR}/error.log
        CustomLog ${APACHE_LOG_DIR}/access.log combined
      </VirtualHost>" > /etc/apache2/sites-enabled/000-default.conf
      
      certbot certonly -n --agree-tos --standalone -m rodrigo.graeff@viewdeck.com -d vpn.dev.myvcl.com
      
      sleep 5
      $SYSTEMCTL_PATH restart apache2
    }

    function network_conf() {
      echo ""
      echo "### Enable ipv4 Forwarding"
      sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
      sysctl -p
    }

    function firewall_conf() {
      echo ""
      echo "### Firewall configuration"

      if [ ! $(which iptables)  ]; then
        echo ""
        msg info "iptables is required. Let's install it."
        apt -qq install iptables -y
      fi

      if [ ! $(which ifup)  ]; then
        echo ""
        msg info "ifupdown is required. Let's install it."
        apt -qq install ifupdown -y
      fi

      if [ ! -d /etc/iptables ]; then
        mkdir -m 755 /etc/iptables
      fi

      # Stop fail2ban if it present to don't save banned IPs
      if [ $(which fail2ban-client) ]; then
        fail2ban-client stop
      fi

      # Backup actual firewall configuration
      /sbin/iptables-save > /etc/iptables/rules.v4.bak
      /sbin/ip6tables-save > /etc/iptables/rules.v6.bak

      if [ "$STRICT_FIREWALL" == "n" ]; then
        RULES_4=(
        "INPUT -i $WG_INTERFACE -m comment --comment wireguard-network -j ACCEPT"
        "INPUT -p udp -m udp --dport $WG_PORT -i $SYS_INTERFACE -m comment --comment external-port-wireguard -j ACCEPT"
        "FORWARD -s $WG_NETWORK -i $WG_INTERFACE -o $SYS_INTERFACE -m comment --comment Wireguard-traffic-from-$WG_INTERFACE-to-$SYS_INTERFACE -j ACCEPT"
        "FORWARD -d $WG_NETWORK -i $SYS_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-from-$SYS_INTERFACE-to-$WG_INTERFACE -j ACCEPT"
        #"FORWARD -d $WG_NETWORK -i $WG_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-inside-$WG_INTERFACE -j ACCEPT"
        "POSTROUTING -t nat -s $WG_NETWORK -o $SYS_INTERFACE -m comment --comment wireguard-nat-rule -j MASQUERADE"
        )
      elif [ "$STRICT_FIREWALL" == "y" ]; then
        RULES_4=(
        "INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "INPUT -i lo -m comment --comment localhost-network -j ACCEPT"
        "INPUT -i $WG_INTERFACE -m comment --comment wireguard-network -j ACCEPT"
        "INPUT -p tcp -m tcp --dport $SSH_PORT -j ACCEPT"
        "INPUT -p icmp -m icmp --icmp-type 8 -m comment --comment Allow-ping -j ACCEPT"
        "INPUT -p udp -m udp --dport $WG_PORT -i $SYS_INTERFACE -m comment --comment external-port-wireguard -j ACCEPT"
        "FORWARD -s $WG_NETWORK -i $WG_INTERFACE -o $SYS_INTERFACE -m comment --comment Wireguard-traffic-from-$WG_INTERFACE-to-$SYS_INTERFACE -j ACCEPT"
        "FORWARD -d $WG_NETWORK -i $SYS_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-from-$SYS_INTERFACE-to-$WG_INTERFACE -j ACCEPT"
        #"FORWARD -d $WG_NETWORK -i $WG_INTERFACE -o $WG_INTERFACE -m comment --comment Wireguard-traffic-inside-$WG_INTERFACE -j ACCEPT"
        "FORWARD -p tcp --syn -m limit --limit 1/second -m comment --comment Flood-&-DoS -j ACCEPT"
        "FORWARD -p udp -m limit --limit 1/second -m comment --comment Flood-&-DoS -j ACCEPT"
        "FORWARD -p icmp --icmp-type echo-request -m limit --limit 1/second -m comment --comment Flood-&-DoS -j ACCEPT"
        "FORWARD -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -m comment --comment Port-Scan -j ACCEPT"
        "OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "OUTPUT -o lo -m comment --comment localhost-network -j ACCEPT"
        "OUTPUT -p tcp -m tcp --dport 443 -j ACCEPT"
        "OUTPUT -p tcp -m tcp --dport 80 -j ACCEPT"
        "OUTPUT -p tcp -m tcp --dport 22 -j ACCEPT"
        "OUTPUT -p udp -m udp --dport 53 -j ACCEPT"
        "OUTPUT -p tcp -m tcp --dport 53 -j ACCEPT"
        "OUTPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT"
        "POSTROUTING -t nat -s $WG_NETWORK -o $SYS_INTERFACE -m comment --comment wireguard-nat-rule -j MASQUERADE"
        )

        RULES_6=(
        "INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "INPUT -i lo -m comment --comment localhost-network -j ACCEPT"
        "OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT"
        "OUTPUT -o lo -m comment --comment localhost-network -j ACCEPT"
        )

        # Change default policy to DROP instead ACCEPT
        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT DROP
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT DROP
      fi

      # Apply rules only if they are not already present
      if [ ! -z "$RULES_4" ]; then
        for e in "${RULES_4[@]}"; do
          iptables -C $e > /dev/null 2>&1 || iptables -A $e
        done
      fi

      if [ ! -z "$RULES_6" ]; then
        for e in "${RULES_6[@]}"; do
          ip6tables -C $e > /dev/null 2>&1 || ip6tables -A $e
        done
      fi

      # Backup allrules (old and new)
      /sbin/iptables-save > /etc/iptables/rules.v4
      /sbin/ip6tables-save > /etc/iptables/rules.v6

      # Restart Fail2ban
      if [ $(which fail2ban-client) ]; then
        fail2ban-client start
      fi

      # Make a script for a persistent configuration
      echo "#!/bin/sh
      /sbin/iptables-restore < /etc/iptables/rules.v4
      /sbin/ip6tables-restore < /etc/iptables/rules.v6" > /etc/network/if-up.d/iptables
      chmod 755 /etc/network/if-up.d/iptables
    }

    function wg_conf() {
      echo ""
      echo "### Making default Wireguard conf"
      umask 077 /etc/wireguard/
      touch /etc/wireguard/$WG_INTERFACE.conf
      $SYSTEMCTL_PATH enable wg-quick@$WG_INTERFACE.service
    }

    function wgui_conf() {
      echo ""
      echo "### Wiregard-ui Services"
      echo "[Unit]
      Description=Wireguard UI
      After=network.target

      [Service]
      Type=simple
      WorkingDirectory=$WGUI_PATH
      ExecStart=$WGUI_BIN_PATH/wireguard-ui

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/wgui_http.service

      echo "[Unit]
      Description=Restart WireGuard
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=$SYSTEMCTL_PATH restart wg-quick@$WG_INTERFACE.service" > /etc/systemd/system/wgui.service

      echo "[Unit]
      Description=Watch /etc/wireguard/$WG_INTERFACE.conf for changes

      [Path]
      PathModified=/etc/wireguard/$WG_INTERFACE.conf

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/wgui.path
      PASS="$(pwgen -s 15 -1)"
      echo "{
      "username": "admin",
      "password": "$PASS"
    }" > /opt/wgui/db/server/users.json
    
      $SYSTEMCTL_PATH enable wgui_http.service
      $SYSTEMCTL_PATH start wgui_http.service
      $SYSTEMCTL_PATH enable wgui.{path,service}
      $SYSTEMCTL_PATH start wgui.{path,service}
       
    }

    function msg(){
      local GREEN="\\033[1;32m"
      local NORMAL="\\033[0;39m"
      local RED="\\033[1;31m"
      local PINK="\\033[1;35m"
      local BLUE="\\033[1;34m"
      local WHITE="\\033[0;02m"
      local YELLOW="\\033[1;33m"
      if [ "$1" == "ok" ]; then
        echo -e "[$GREEN  OK  $NORMAL] $2"
      elif [ "$1" == "ko" ]; then
        echo -e "[$RED ERROR $NORMAL] $2"
      elif [ "$1" == "warn" ]; then
        echo -e "[$YELLOW WARN $NORMAL] $2"
      elif [ "$1" == "info" ]; then
        echo -e "[$BLUE INFO $NORMAL] $2"
      fi
    }

    function not_supported_os(){
      msg ko "Oops This OS is not supported yet !"
      echo "    Do not hesitate to contribute for a better compatibility
                https://gitlab.com/snax44/wireguard-ui-setup"
    }

    function detect_os(){
      if [[ "$OS_DETECTED" == "debian" ]]; then
        if grep -q "bullseye" /etc/os-release; then
          msg info "OS detected : Debian 11 (Bullseye)"
          main
        elif grep -q "buster" /etc/os-release; then
          msg info "OS detected : Debian 10 (Buster)"
          BACKPORTS_REPO="deb https://deb.debian.org/debian/ buster-backports main"
          main
        fi
      elif [[ "$OS_DETECTED" == "ubuntu" ]]; then
        if grep -q "focal" /etc/os-release; then
          msg info "OS detected : Ubuntu Focal (20.04)"
          main
        elif grep -q "groovy" /etc/os-release; then
          msg info "OS detected : Ubuntu Groovy (20.10)"
          main
        elif grep -q "hirsute" /etc/os-release; then
          msg info "OS detected : Ubuntu Hirsute (21.04)"
          main
        elif grep -q "impish" /etc/os-release; then
          msg info "OS detected : Ubuntu Impish (21.10)"
          main
        elif grep -q "Jammy" /etc/os-release; then
          msg info "OS detected : Ubuntu Jammy (22.04)"
          main
        fi
      elif [[ "$OS_DETECTED" == "fedora" ]]; then
        msg info "OS detected : Fedora"
        not_supported_os
      elif [[ "$OS_DETECTED" == "centos" ]]; then
        msg info "OS detected : Centos"
        not_supported_os
      elif [[ "$OS_DETECTED" == "arch" ]]; then
        msg info "OS detected : Archlinux"
        not_supported_os
      else
        if $CONTINUE_ON_UNDETECTED_OS; then
          msg warn "Unable to detect os. Keep going anyway in 5s"
          sleep 5
          main
        else
          msg ko "Unable to detect os and CONTINUE_ON_UNDETECTED_OS is set to false"
          exit 1
        fi
      fi
    }

    if ! [ $(id -nu) == "root" ]; then
      msg ko "Oops ! Please run this script as root"
      exit 1
    fi
    detect_os
