# Throwaway JOSE key material for the JWT specs — generated once and COMMITTED, not minted at
# spec time: ECDSA and RSA-PSS signing are randomized, so the only stable assertions are
# "verifies" and "round-trips", and a fresh key per run would make a failure unreproducible.
# The Ed25519 pair is the exception and the reason this file exists: it is RFC 8037 Appendix
# A.4's key, so Ed25519 signing has a byte-exact known answer to check against.
#
# None of these protect anything. Do not copy them into a real deployment.
module JoseKeys
  EC256 = <<-PEM
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIPxEPpo9ItZiLtLl2+jQ6Ksh4dH4rO1hBdQ5fuuWMGBhoAoGCCqGSM49
    AwEHoUQDQgAENC3lluhyoFe8n7ipXfXxda8BJhY1NZonDxSvwPZGwQxpmvsSh66E
    GGl1Fb3YFf69HxIW53tGMoxUK5qXJPG61A==
    -----END EC PRIVATE KEY-----
    PEM

  EC256_PUB = <<-PEM
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAENC3lluhyoFe8n7ipXfXxda8BJhY1
    NZonDxSvwPZGwQxpmvsSh66EGGl1Fb3YFf69HxIW53tGMoxUK5qXJPG61A==
    -----END PUBLIC KEY-----
    PEM

  EC384 = <<-PEM
    -----BEGIN EC PRIVATE KEY-----
    MIGkAgEBBDAG6yYqMNbZ4nhSd7TTt3snYxLBo1wyTclQTDu7/+GR8dv64HeDsFTv
    A+0phEUnE9SgBwYFK4EEACKhZANiAARtoHUm9paWH3D2iiIX80S0c9MUmskxEobs
    AibTuarpWtPNs6TxHgWLW+u6YHKYDf97gdwivb9ypfZlD7sPyv869beJFP5aYkuT
    35SktvZgIs21kd+brFpUApBsBEBAy2M=
    -----END EC PRIVATE KEY-----
    PEM

  EC384_PUB = <<-PEM
    -----BEGIN PUBLIC KEY-----
    MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbaB1JvaWlh9w9ooiF/NEtHPTFJrJMRKG
    7AIm07mq6VrTzbOk8R4Fi1vrumBymA3/e4HcIr2/cqX2ZQ+7D8r/OvW3iRT+WmJL
    k9+UpLb2YCLNtZHfm6xaVAKQbARAQMtj
    -----END PUBLIC KEY-----
    PEM

  EC521 = <<-PEM
    -----BEGIN EC PRIVATE KEY-----
    MIHcAgEBBEIBwb6oiNbzk11KWrTHG7fcZ3IcHoyFtPsWPag/HC4dzItgP1U852AD
    WlqDWp/s2dNMZERNVdeoqWbfg7Z6jDFhiTSgBwYFK4EEACOhgYkDgYYABAAa6dP8
    xeTK/OTQI+d4X6Oh2JYY8WHH0QLZbdePVNNW62cct+fFqB5bTd8BrBn0qdeM/ABF
    bL2G/04+Y/3azXFvjgHggTB6lXZwxMwtqzm7m6FS86H44vGm7042NU3WlsoEHuzn
    2UrOVQkAYNB1ncmM5OPpJ9avDb2NhYkU0j4uF/EsCQ==
    -----END EC PRIVATE KEY-----
    PEM

  EC521_PUB = <<-PEM
    -----BEGIN PUBLIC KEY-----
    MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQAGunT/MXkyvzk0CPneF+jodiWGPFh
    x9EC2W3Xj1TTVutnHLfnxageW03fAawZ9KnXjPwARWy9hv9OPmP92s1xb44B4IEw
    epV2cMTMLas5u5uhUvOh+OLxpu9ONjVN1pbKBB7s59lKzlUJAGDQdZ3JjOTj6SfW
    rw29jYWJFNI+LhfxLAk=
    -----END PUBLIC KEY-----
    PEM

  RSA = <<-PEM
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCNxXUi7PcJupoO
    NCY+BvDbvsa2u/wsw4Ev4nsbSkwJhtLMsnaszATEEIEGPfzxU7upLZhkShwSC/Ed
    Vnbe81WbTTRGqMAOl1bOeiwRr+twsFBPcoss3Xx3XVSnNr9xbuma90PQsne/3fyn
    uoUQYsKO06usS1jF00CV5rLVAYkJ68wkQiABEHooqA7OV5+qfIq2Ysx4uaC4ASdc
    8A1q6ZqJy0X83tvxURt/U4HQISeDUxwCGNxHu8f8MURYXbuNVP+NG6iqpgvmCviZ
    EmAWuywZH1XUJLvdbmqJ5f3wFWKMFJ++5Rxo0jpRE/V7EHj7woMKfs7jVdyOo9RC
    hOurS60zAgMBAAECggEAK4eN1EfzABs58xODDHeAG9CjXfcxUiNDNssw5mu1FhW+
    AtjnBF5uNi8lFqAQ2p5Nl//mcyCoJshg45OpUwJe7hzR6MImmjRQlHxBrLqZrVON
    jR9L6V4mOdY/yEnQlUkrVAgI2/r4NsK3sV5dPe888rK+WtwVqUQYaA5aKXnbtF4r
    lx9FO3G4J8kc77o/+ysXHkiP9uFORL/Tbe6PgHoBbYrTxCYiXPJ99NU0ZxPvxwZx
    qFpUj4BYIBxrCUW6EK4WHz9Eb0+Uoa66T+f/ihDe8wBXDEq5R/FYrVOrbN/eUk+a
    ioai6mKAnevlQpoQSdVN/tqZ1TGvDMw300XcfoKVSQKBgQDErKNtlsOaJY6jsWSQ
    T9Ea0OQ/eSSQmD/UJT5xD0AsvF6DkXW7QBKXCHE2ZUdPzn/OYoHGk5GOHYjpsFU6
    ZNQuZ0zV344NTMsGHGry5JHt2xLFJskHQvmh4XytYc5SMwMe8+eZRWvSPxHSAUyc
    6+uPho5MXtQDumOSi8Sv/t6HyQKBgQC4iSi4eX22vdsg1/fNevUYIoNztSX4z2Uc
    +URFj6tqLrHRPBeXfXX5ZS3cWZ1U9ki2g13MYdkToLT4+U4Lo6NkSXgjpCHV9gIc
    k4L6fi05lnUdUw2vuOlFoYfbb45wRsZk0mEqP7UrO/21f+sfEGKxVUexHWUCYTBq
    iGOoUlwDGwKBgG1UBpkx2NQEkrE+OEfchsHgYzFBl2jlqX21omtY7fSwVd3Pa2HG
    8U6R+9UgIa8kfHlu2vNXLu+QTX6Sbh5C1IxjEhxF5IJSMP3ZqD4Tf2d4g4uiztdB
    jOFHJnZ/SyD4iICZVyIlrBU4yCA0ZrFImC61vr6HbFYSM63QEms/Q9a5AoGBAKNb
    yFCGPGOpbnKEvTmJv6693uBvXE4GStx7TZTGulglPgSbzcatqeI9T3vhWQX9gCER
    6dckR6a4fXxqNkzXb6033MKwacOfI/9oFmrph9+S8dojy9njN54MgNggyVdbUAWw
    t5NPEnJTiSVDOEEnoDab5/tCqkiRAOtOEerP/eRBAoGBALwCthMUWpMWqtZeZM9p
    mZXLEWYrqIcNYJu+PueJuvbumQIBwmRfNxRxLEnm0MOoD66SwoeBQ5CNI6HYA+gh
    mSWGnjRPN8GNSuTwIxzwnRYsdvc7KsnL8RBaLFnjHg5NCAauZMtUM2POGS1izVU1
    cjapyBYQkYqoFroqdoT9LE7b
    -----END PRIVATE KEY-----
    PEM

  RSA_PUB = <<-PEM
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjcV1Iuz3CbqaDjQmPgbw
    277Gtrv8LMOBL+J7G0pMCYbSzLJ2rMwExBCBBj388VO7qS2YZEocEgvxHVZ23vNV
    m000RqjADpdWznosEa/rcLBQT3KLLN18d11Upza/cW7pmvdD0LJ3v938p7qFEGLC
    jtOrrEtYxdNAleay1QGJCevMJEIgARB6KKgOzlefqnyKtmLMeLmguAEnXPANauma
    ictF/N7b8VEbf1OB0CEng1McAhjcR7vH/DFEWF27jVT/jRuoqqYL5gr4mRJgFrss
    GR9V1CS73W5qieX98BVijBSfvuUcaNI6URP1exB4+8KDCn7O41XcjqPUQoTrq0ut
    MwIDAQAB
    -----END PUBLIC KEY-----
    PEM

  RSA_CERT = <<-PEM
    -----BEGIN CERTIFICATE-----
    MIIC+TCCAeGgAwIBAgIUU1CjfUMo/t+3jh+JgXVmlQJmQ1MwDQYJKoZIhvcNAQEL
    BQAwDDEKMAgGA1UEAwwBdDAeFw0yNjA5MTAwMDMzNTJaFw0yNjA5MTEwMDMzNTJa
    MAwxCjAIBgNVBAMMAXQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCN
    xXUi7PcJupoONCY+BvDbvsa2u/wsw4Ev4nsbSkwJhtLMsnaszATEEIEGPfzxU7up
    LZhkShwSC/EdVnbe81WbTTRGqMAOl1bOeiwRr+twsFBPcoss3Xx3XVSnNr9xbuma
    90PQsne/3fynuoUQYsKO06usS1jF00CV5rLVAYkJ68wkQiABEHooqA7OV5+qfIq2
    Ysx4uaC4ASdc8A1q6ZqJy0X83tvxURt/U4HQISeDUxwCGNxHu8f8MURYXbuNVP+N
    G6iqpgvmCviZEmAWuywZH1XUJLvdbmqJ5f3wFWKMFJ++5Rxo0jpRE/V7EHj7woMK
    fs7jVdyOo9RChOurS60zAgMBAAGjUzBRMB0GA1UdDgQWBBSCRS4kPuxyL1CeGXG4
    fYijc0OHoTAfBgNVHSMEGDAWgBSCRS4kPuxyL1CeGXG4fYijc0OHoTAPBgNVHRMB
    Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAPn4hdI4cufSqW0CvTDLcrYEyw
    FzgOdvGPO1Miw+v5pUj8uT05TpL/pI3COhxmXy1Qj18adXTmoGv2wJS0wNKCgKcg
    1g/QSQkandxSy0W7rEDbCZuoB5GEEIeNma0jhlS+UP0YNaZ2RqQNJoyeeotdQVvJ
    YbvlM0jwhLDJzb4Yh0PjmZ9WAKgW4ApBKPHacbnqFN7Nvp+8RS65K8fg8sK0kCT9
    MQPhMHp9FQjpHJGlxTuWqeF/1j3B6PKmL7gES5ggF3UdrMAgQhCjt/fzXUk918xN
    M3otL82scDMHBipuGAscrAu8Xs/qaJ+oDHj7Cqbuep0eCSV82OyEf/qjG/kj
    -----END CERTIFICATE-----
    PEM

  # RFC 8037 Appendix A.4: d = nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A,
  # x = 11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo. The seed wrapped in the fixed 16-byte
  # Ed25519 PKCS#8 prefix; `openssl pkey -pubout` on it reproduces that exact `x`.
  ED25519 = <<-PEM
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
    -----END PRIVATE KEY-----
    PEM

  ED25519_PUB = <<-PEM
    -----BEGIN PUBLIC KEY-----
    MCowBQYDK2VwAyEA11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=
    -----END PUBLIC KEY-----
    PEM

  # The RFC 8037 A.4 JWS, byte for byte.
  ED25519_KAT_INPUT     = "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc"
  ED25519_KAT_SIGNATURE = "hgyY0il_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_MuM0KAg"

  # Write one of the PEM constants to a file under `dir` and return its path — the other half
  # of every key input (`--key /path/to.pem`), which no inline string can exercise.
  def self.write(dir : String, name : String, pem : String) : String
    path = File.join(dir, name)
    File.write(path, pem)
    path
  end
end
