# Two OpenELIS Global labs exchanging referrals

Two OpenELIS Global laboratories that send each other referrals over FHIR. One command starts both,
already paired:

| Lab | Role | URL | User : password |
|---|---|---|---|
| Lab A, *Kampala Central Laboratory* | refers tests out | <https://localhost:8445> | `admin` : `adminADMIN!` |
| Lab B, *Uganda National Reference Laboratory* | the reference lab | <https://127.0.0.1:8446> | `admin` : `adminADMIN!` |

Lab A refers a test to Lab B. The order appears under Lab B's **Incoming Orders**, Lab B enters and
validates the result, and the result comes back to Lab A, which accepts it.

Guide: [External Referrals (OpenELIS to OpenELIS)](https://uwdigi.atlassian.net/wiki/spaces/OG/pages/1780088834)
(under External Integrations).

Requires OpenELIS images with the referral fixes of
[OpenELIS-Global-2 #5053](https://github.com/DIGI-UW/OpenELIS-Global-2/pull/5053) (merged): `develop` now, then
the next release.

## Start

```bash
docker compose up -d
```

The first start takes 5 to 10 minutes (two databases and two webapps). Docker needs about 6 GB of memory.
The `pair` service waits for both labs and then pairs them; it is done when its log says so:

```bash
docker compose logs pair
# pair: Lab A's reference lab "Uganda National Reference Laboratory" now points at Lab B (<uuid>)
```

Open Lab B at `127.0.0.1`, not `localhost`: browsers share cookies between ports of the same host, so
signing in to one lab on `localhost` would sign you out of the other. The certificates are self-signed;
accept the browser warning.

## Walk through a referral

1. **Lab A** (<https://localhost:8445>): **Order > Add Clinical Order > Enter Order**. Generate a lab
   number, create a patient, add a *Whole Blood* sample with *Lymphocytes (%)*, then **Save and next**.
2. On **Prepare Samples**, under **Refer Out / Subcontract**, choose **Refer Out** on the sample, pick
   *Uganda National Reference Laboratory* as the reference lab, **Save Referral**, then **Save and exit**.
3. Reopen the order on **Prepare Samples**; in the referral row's **Options** menu choose **Dispatch**. The
   status becomes *Requested*.
4. **Lab B** (<https://127.0.0.1:8446>), within about 20 seconds: **Order > Incoming Orders**, search by
   date and status (tick **All Info** to see the test and Lab A's lab number). The requesting facility is
   *Kampala Central Laboratory*. Expand the row, **Generate** a lab number and choose the pencil to open the
   order (or the clipboard to accept it as is), then **Submit**. Lab A's referral becomes *Received*.
5. Lab B: **Results**, enter a value, **Save**; then **Validation**, load the lab number and release it.
6. **Lab A**, within about 20 seconds: **Sample Shipment > Reference Lab Results > Returned, needs action**
   shows the result. **Accept** it: the result is finalized on Lab A's order.

## How it is wired

```text
 Lab A  oe-a ── fhir-a ◄─────────┐   ┌──────── fhir-b ── oe-b  Lab B
   │     writes the referral Task│   │ writes the completed Task and results
   │                             │   │
   └──── reads results from ─────┼───┘
                                 └──────────── reads Tasks owned by Lab B
```

- Each lab has its own database, FHIR server and webapp on its own network (`net-a`, `net-b`). The two
  FHIR servers are also on the `shared` network as `fhir-a.openelis.org` and `fhir-b.openelis.org`.
- Each lab reads the other lab's FHIR server: `org.openelisglobal.remote.source.uri` in
  `configs/lab-a/properties/common.properties` (Lab B's server) and `configs/lab-b/properties/common.properties`
  (Lab A's server), polled every 20 seconds (`org.openelisglobal.remote.poll.frequency`).
- A referral is a FHIR `Task` whose owner is the reference lab's facility `Organization`. Lab B picks up
  the Tasks owned by its own facility, so `org.openelisglobal.remote.source.identifier` keeps its default.
- Pairing: Lab A must know Lab B's facility FHIR id. Lab B shows it on its own facility record (**Admin >
  Locations & Organizations > Organizations**, *This laboratory*), and Lab A stores it on its reference lab, in the
  field **FHIR id at the reference lab**. `scripts/pair.sh` (the `pair` service) does exactly that through
  the Locations API, and creates the reference lab on Lab A when it is missing. It is safe to run again:
  `docker compose run --rm pair`.
- Lab names and lab number prefixes (`KCL01`, `UNR01`): `localization.en.BANNER_TEXT` and
  `ACCESSION_NUMBER_PREFIX` in each lab's `configs/lab-*/properties/SystemConfiguration.properties`, applied
  at every start.
- Both labs trust each other because they share one certificate store (the `certs` service). Two labs on
  different servers must each import the other's FHIR server certificate into their truststore.

## Stop and reset

```bash
docker compose down        # stop, keep the data
docker compose down -v     # stop and delete both labs' data
```

After `down -v` both labs start empty and get new FHIR ids; the `pair` service pairs them again.

## For production

- `.env` and `secrets/initial-admin-password` hold demo values so that the setup starts as is. Set private
  values before the first start.
- Each lab runs its own [openelis-docker](https://github.com/DIGI-UW/openelis-docker) installation. Set
  `org.openelisglobal.remote.source.uri` to the other lab's FHIR server, make the two FHIR servers reachable
  from each other over HTTPS, import each other's certificates, and record the reference lab's facility
  FHIR id on the referring lab under **Admin > Locations & Organizations > Organizations**.
