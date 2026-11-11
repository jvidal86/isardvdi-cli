// fakeportal is a development tool: a stand-in IsardVDI portal for trying the CLI, on any
// platform, without a real account. It serves a few canned answers over HTTPS with a throwaway
// certificate and writes that certificate to the file named by -ca (use it as ISARDVDI_CA_FILE).
//
//	fakeportal -ca ca.pem -addr 127.0.0.1:0 -urlfile url.txt
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"
)

const desktops = `{"desktops":[
 {"id":"0cf16815-bffb-449b-8949-6757e049299a","name":"Linux Lab","status":"Started","ip":"10.2.0.5"},
 {"id":"1cf16815-bffb-449b-8949-6757e049299a","name":"Windows Lab","status":"Stopped","ip":null},
 {"id":"2cf16815-bffb-449b-8949-6757e049299a","name":"Evil\u001b[2J\tName","status":"Stopped"}]}`

const info = `{"id":"0cf16815-bffb-449b-8949-6757e049299a","name":"Linux Lab","status":"Stopped","ip":null,"interfaces":{"wireguard":{"ip":"10.2.0.5"}}}`

func main() {
	caFile := flag.String("ca", "ca.pem", "write the server certificate here")
	addr := flag.String("addr", "127.0.0.1:0", "listen address")
	urlFile := flag.String("urlfile", "", "write the server URL here")
	flag.Parse()

	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "fakeportal"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IsCA: true, BasicConstraintsValid: true, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, DNSNames: []string{"localhost"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		log.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	if err := os.WriteFile(*caFile, certPEM, 0o600); err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v4/items/desktops", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, desktops) })
	mux.HandleFunc("/api/v4/item/desktop/0cf16815-bffb-449b-8949-6757e049299a/get-info", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, info) })
	mux.HandleFunc("/echo-auth", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, r.Header.Get("Authorization")) })
	ln, err := tls.Listen("tcp", *addr, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, MinVersion: tls.VersionTLS12})
	if err != nil {
		log.Fatal(err)
	}
	url := "https://" + ln.Addr().String()
	if *urlFile != "" {
		if err := os.WriteFile(*urlFile, []byte(url), 0o600); err != nil {
			log.Fatal(err)
		}
	}
	log.Println("fakeportal on", url)
	log.Fatal(http.Serve(ln, mux))
}
