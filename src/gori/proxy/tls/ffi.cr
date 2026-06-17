require "openssl"

# LibCrypto/LibSSL functions the Crystal stdlib doesn't expose, needed to mint
# and sign certificates in-process and inject them into a stdlib SSL context.
# Validated end-to-end against OpenSSL 3.x (see SPIKE 1). Type aliases use names
# not already defined by stdlib to avoid collisions; `X509`, `X509_NAME`, `Bio`,
# `EVP_MD`, `EC_KEY`, `X509_EXTENSION` etc. are reused from stdlib.
lib LibCrypto
  type EVP_PKEY = Void*
  type ASN1_TIME = Void*
  type ASN1_INT = Void*

  # key generation (EC P-256 via the high-level EVP path)
  fun ec_key_generate_key = EC_KEY_generate_key(key : EC_KEY) : Int
  fun evp_pkey_new = EVP_PKEY_new : EVP_PKEY
  fun evp_pkey_free = EVP_PKEY_free(pkey : EVP_PKEY)
  fun evp_pkey_assign = EVP_PKEY_assign(pkey : EVP_PKEY, type : Int, key : Void*) : Int

  # X509 construction + signing
  fun x509_set_version = X509_set_version(x : X509, version : Long) : Int
  fun x509_set_pubkey = X509_set_pubkey(x : X509, pkey : EVP_PKEY) : Int
  fun x509_set_issuer_name = X509_set_issuer_name(x : X509, name : X509_NAME) : Int
  fun x509_get_serial = X509_get_serialNumber(x : X509) : ASN1_INT
  fun asn1_integer_set = ASN1_INTEGER_set(a : ASN1_INT, v : Long) : Int
  fun x509_getm_not_before = X509_getm_notBefore(x : X509) : ASN1_TIME
  fun x509_getm_not_after = X509_getm_notAfter(x : X509) : ASN1_TIME
  fun x509_gmtime_adj = X509_gmtime_adj(s : ASN1_TIME, adj : Long) : ASN1_TIME
  fun x509_sign = X509_sign(x : X509, pkey : EVP_PKEY, md : EVP_MD) : Int
  fun x509_store_add_cert = X509_STORE_add_cert(store : X509_STORE, x : X509) : Int

  # PEM persistence via file BIOs (root CA only; leaves stay in memory)
  fun bio_new_file = BIO_new_file(filename : Char*, mode : Char*) : Bio*
  fun pem_write_bio_x509 = PEM_write_bio_X509(bio : Bio*, x : X509) : Int
  fun pem_read_bio_x509 = PEM_read_bio_X509(bio : Bio*, x : X509*, cb : Void*, u : Void*) : X509
  fun pem_write_bio_privatekey = PEM_write_bio_PrivateKey(bio : Bio*, pkey : EVP_PKEY, enc : Void*,
                                                          kstr : UInt8*, klen : Int, cb : Void*, u : Void*) : Int
  fun pem_read_bio_privatekey = PEM_read_bio_PrivateKey(bio : Bio*, pkey : EVP_PKEY*, cb : Void*, u : Void*) : EVP_PKEY
end

lib LibSSL
  fun ssl_ctx_use_certificate = SSL_CTX_use_certificate(ctx : SSLContext, x : LibCrypto::X509) : Int
  fun ssl_ctx_use_privatekey = SSL_CTX_use_PrivateKey(ctx : SSLContext, pkey : LibCrypto::EVP_PKEY) : Int
  fun ssl_ctx_get_cert_store = SSL_CTX_get_cert_store(ctx : SSLContext) : LibCrypto::X509_STORE
end

module Gori::Proxy::Tls
  # OpenSSL NID / flag constants.
  NID_PRIME256V1   = 415 # NID_X9_62_prime256v1 (P-256)
  EVP_PKEY_EC      = 408 # NID_X9_62_id_ecPublicKey
  NID_BASIC_CONSTR =  87 # NID_basic_constraints
  NID_SUBJECT_ALT  =  85 # NID_subject_alt_name

  CA_VALIDITY_SECS   = 60_i64 * 60 * 24 * 3650 # ~10 years
  LEAF_VALIDITY_SECS = 60_i64 * 60 * 24 * 397  # ~13 months (browser leaf cap)
end
