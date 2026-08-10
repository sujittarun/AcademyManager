-- ============================================================
-- 2026-08-11j · Make the compatibility views faithful again
-- scope: shared
--
-- The manager signed in after the cutover: roster, finance and attendance
-- were right, but renewals, overdue days and reminder dues were wrong.
--
-- Cause: 2026-08-10q moved seven columns from the side table onto members
-- (reg_no, added_by, updated_by, rejoined_at and the reminder-pause trio),
-- and the transform correctly stopped writing them to student_details —
-- but genalpha.students still read them from d.*, so the app saw NULL.
-- Comparing one row against the source showed it exactly:
--
--   reg_no      old 1013                    view NULL
--   added_by    old "Admission Form"        view NULL
--   rejoined_at old 2026-08-03              view NULL
--   whatsapp_reminders_paused*              NOT EXPOSED AT ALL
--
-- The reminder-pause trio is the one that broke reminders: the app reads
-- student.whatsapp_reminders_paused, got undefined, and its dues logic
-- went with it. The data was never wrong — all 81 members carry reg_no
-- and added_by, and every paid_through matches the source exactly. The
-- view was reading the wrong side of the join.
--
-- Two fields were genuinely lost and are restored here from the source
-- project, which is still live: `age` (GenAlpha stores an integer and has
-- no dob, so deriving age from dob returned 0) and the original
-- created_at/updated_at, which the merge replaced with migration time.
-- ============================================================

alter table genalpha.student_details add column if not exists age integer;
alter table genalpha.student_details add column if not exists source_created_at timestamptz;
alter table genalpha.student_details add column if not exists source_updated_at timestamptz;

update genalpha.student_details d
   set age               = (x->>'age')::int,
       source_created_at = (x->>'created_at')::timestamptz,
       source_updated_at = (x->>'updated_at')::timestamptz
  from jsonb_array_elements('[{"uu": "42d717ac-15ae-4a0a-b57d-8903c5961a16", "age": 6, "created_at": "2026-07-26T15:55:29.106269+05:30", "updated_at": "2026-07-26T15:55:57.459232+05:30"}, {"uu": "5d2434db-9f21-4a50-aa8e-11eb3e69229a", "age": 11, "created_at": "2026-07-16T20:47:55.992677+05:30", "updated_at": "2026-07-16T21:02:03.006837+05:30"}, {"uu": "2ca23c39-50b8-456c-a2a1-602d2b3fc831", "age": 6, "created_at": "2026-06-23T11:21:16.859972+05:30", "updated_at": "2026-07-21T17:55:36.978285+05:30"}, {"uu": "63b45af7-12f3-48a9-9a5e-9e8a2e74c64d", "age": 14, "created_at": "2026-04-27T20:35:38.985+05:30", "updated_at": "2026-07-22T09:51:03.625401+05:30"}, {"uu": "ef5515a4-ae2b-4a06-8fab-54efe68568a2", "age": 5, "created_at": "2026-07-06T19:32:41.366382+05:30", "updated_at": "2026-08-06T16:53:33.904901+05:30"}, {"uu": "5bcca232-2b22-4570-afa6-88897fadf234", "age": 11, "created_at": "2026-08-07T08:25:09.555718+05:30", "updated_at": "2026-08-09T22:24:34.795314+05:30"}, {"uu": "624ca081-94ba-456d-b784-a989f1497221", "age": 7, "created_at": "2026-05-07T19:11:04.8668+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "b94d9d7b-fdd3-4c2d-8193-3b5c3bc9339d", "age": 12, "created_at": "2026-07-10T09:27:28.464481+05:30", "updated_at": "2026-07-10T09:27:40.843344+05:30"}, {"uu": "4f8f34e4-a46c-415a-8960-2d3d201e8bb4", "age": 8, "created_at": "2026-04-27T21:23:21.039843+05:30", "updated_at": "2026-07-16T22:07:33.255238+05:30"}, {"uu": "78c9cadb-d101-481e-9a44-33bfe5a7eeb6", "age": 9, "created_at": "2026-04-27T19:40:54.126917+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "9334cde1-fe97-459b-b979-2820a9b3d2cf", "age": 13, "created_at": "2026-05-02T16:20:51.211689+05:30", "updated_at": "2026-07-16T21:54:51.02492+05:30"}, {"uu": "2140ecdc-985e-4847-8e5a-dc312e65ba32", "age": 7, "created_at": "2026-04-27T20:52:46.592003+05:30", "updated_at": "2026-07-16T21:55:14.721293+05:30"}, {"uu": "9dacd20b-5f11-41e2-b05e-d7a6410644aa", "age": 12, "created_at": "2026-07-16T21:57:33.318067+05:30", "updated_at": "2026-07-16T21:58:13.283001+05:30"}, {"uu": "15489a93-39d1-43a4-93e3-e80603f8aa1f", "age": 12, "created_at": "2026-04-27T21:06:20.612902+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "5b3d33b0-260f-4655-a879-4d6fdb771ee7", "age": 10, "created_at": "2026-04-27T19:18:50.387301+05:30", "updated_at": "2026-07-16T22:02:31.397458+05:30"}, {"uu": "2ae15939-e02b-4b43-ba02-d16471984789", "age": 8, "created_at": "2026-04-27T18:38:56.589918+05:30", "updated_at": "2026-07-16T22:02:35.82666+05:30"}, {"uu": "82a2c667-506d-4841-a7d3-f9109471d2eb", "age": 6, "created_at": "2026-04-27T20:14:15.373156+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "86d62a7c-64a7-4976-ac5d-e71aa0ee6541", "age": 7, "created_at": "2026-06-02T10:28:41.844315+05:30", "updated_at": "2026-07-20T17:00:23.701681+05:30"}, {"uu": "32ff0e8d-f038-4db8-b764-c21916c63a5d", "age": 7, "created_at": "2026-06-18T21:10:22.128769+05:30", "updated_at": "2026-07-20T18:20:28.523176+05:30"}, {"uu": "b0376368-f501-4aca-ac10-6b2502d6421c", "age": 8, "created_at": "2026-06-23T20:12:53.602801+05:30", "updated_at": "2026-07-26T15:57:33.969926+05:30"}, {"uu": "1f835dc8-8f47-4f92-bccf-9d0ff51268e5", "age": 5, "created_at": "2026-06-18T08:05:28.829813+05:30", "updated_at": "2026-07-29T17:23:22.855246+05:30"}, {"uu": "7d47e3f2-6265-49dc-98c6-1b5502bcec55", "age": 9, "created_at": "2026-06-23T20:24:28.769626+05:30", "updated_at": "2026-07-29T17:23:55.953743+05:30"}, {"uu": "424a0a56-bcc9-43c1-b74f-f1f1a72b6a23", "age": 8, "created_at": "2026-04-27T19:30:12.143716+05:30", "updated_at": "2026-08-03T20:42:34.913713+05:30"}, {"uu": "c0406543-4bf5-4a18-90a8-047cba35f6a8", "age": 16, "created_at": "2026-06-01T16:46:07.127477+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "6989774c-842b-4e9d-8543-0902ceea316a", "age": 12, "created_at": "2026-05-29T08:02:19.651377+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "94d2e523-cf96-4a08-b2b7-d96fbf91d296", "age": 11, "created_at": "2026-07-20T16:52:59.018036+05:30", "updated_at": "2026-07-20T16:53:17.411585+05:30"}, {"uu": "65b064a0-ff93-4dfa-8544-58ef9c2bae65", "age": 6, "created_at": "2026-06-23T10:56:43.150869+05:30", "updated_at": "2026-07-24T23:42:49.919789+05:30"}, {"uu": "1cda6dbe-fa1a-4d70-9e2d-36dbf6a2486c", "age": 6, "created_at": "2026-06-18T07:40:10.109709+05:30", "updated_at": "2026-07-27T18:01:01.388008+05:30"}, {"uu": "b9b07b18-165a-451c-a1fb-804b03e75fc3", "age": 8, "created_at": "2026-07-29T17:28:11.365258+05:30", "updated_at": "2026-07-29T17:28:28.027372+05:30"}, {"uu": "19ed3b82-4ad0-404a-bf80-9d7d6d255f7d", "age": 5, "created_at": "2026-05-22T19:28:01.981769+05:30", "updated_at": "2026-07-31T19:15:42.201233+05:30"}, {"uu": "9eab6729-0a1e-4d28-9337-f25475035c59", "age": 12, "created_at": "2026-08-04T00:08:03.613093+05:30", "updated_at": "2026-08-04T00:20:00.378369+05:30"}, {"uu": "086c7e03-1990-46f5-91c8-0f510c3b6d2e", "age": 11, "created_at": "2026-07-16T15:10:14.589351+05:30", "updated_at": "2026-07-16T21:50:23.774268+05:30"}, {"uu": "a3a0eebe-28d6-4599-b13d-1ab78bc8af06", "age": 9, "created_at": "2026-06-29T18:52:42.566672+05:30", "updated_at": "2026-07-22T09:57:43.846878+05:30"}, {"uu": "ea9f82a6-7194-427f-bbcf-d1718894e3dd", "age": 9, "created_at": "2026-07-29T17:30:27.946797+05:30", "updated_at": "2026-07-29T17:30:40.460581+05:30"}, {"uu": "c4201bd5-0fda-41da-89a3-f6f189de0a0f", "age": 9, "created_at": "2026-08-06T19:44:24.760542+05:30", "updated_at": "2026-08-06T19:45:05.63239+05:30"}, {"uu": "09f64e0e-3156-4d64-8d31-eb379538a95d", "age": 6, "created_at": "2026-06-30T16:12:46.834417+05:30", "updated_at": "2026-08-06T22:35:58.783823+05:30"}, {"uu": "93433488-c5f6-4b61-92d4-0dc7475b7c29", "age": 7, "created_at": "2026-07-06T16:32:35.300303+05:30", "updated_at": "2026-07-06T16:32:56.416651+05:30"}, {"uu": "0915f35c-4a27-4181-82c9-47c76e54de47", "age": 9, "created_at": "2026-05-11T08:45:36.138436+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "6bcccd72-e7b8-4fae-bc16-d71cf8d92dcf", "age": 8, "created_at": "2026-04-27T19:57:54.884286+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "84db407f-c83e-4220-a653-e0c69bfd59e1", "age": 15, "created_at": "2026-05-29T08:04:22.424747+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "8c24ffc2-b021-42ff-8448-42ed41db6d9b", "age": 10, "created_at": "2026-05-18T18:01:32.169526+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "ae4199a7-2259-4061-83ad-e7b4c6e45fa8", "age": 13, "created_at": "2026-04-27T21:30:34.162086+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "82778d58-410a-4801-8866-b1c568e9a465", "age": 13, "created_at": "2026-04-27T19:27:05.692201+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "e54593b0-dc8c-447b-a4c3-4a962a87c5bc", "age": 7, "created_at": "2026-05-02T17:36:40.78133+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "94bb6e50-973d-49ba-b18e-19f326c78917", "age": 9, "created_at": "2026-04-27T19:33:11.737734+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "6e336522-b6e1-4b59-8429-2208d9cae5d9", "age": 13, "created_at": "2026-04-27T22:10:23.553752+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "4b69a418-c7c2-4d56-a693-44e16b66d213", "age": 12, "created_at": "2026-04-27T19:35:22.29833+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "80da9abd-10e5-4116-9bda-cdee1985038f", "age": 10, "created_at": "2026-04-27T20:23:33.169627+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "fe37a48b-ad58-480a-a4ad-48f5549719a3", "age": 6, "created_at": "2026-05-02T16:37:47.770633+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "f2c5673f-f5e6-409d-80f4-fed671a6a6f3", "age": 8, "created_at": "2026-05-02T16:47:27.981028+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "1005c4f1-d675-4225-95fc-7c05d13cd345", "age": 10, "created_at": "2026-04-27T23:03:27.389914+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "08de0824-c52c-4c40-a3f6-7d930041e820", "age": 9, "created_at": "2026-04-27T21:18:13.142001+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "d9df2ad3-efad-42f9-81bf-9649075b1ac2", "age": 14, "created_at": "2026-05-02T17:23:17.166011+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "003daa64-a85d-469e-9ea4-7b025c8d0838", "age": 10, "created_at": "2026-04-27T20:20:19.524829+05:30", "updated_at": "2026-08-06T20:25:37.23227+05:30"}, {"uu": "94836cad-ff67-4fa1-bd3b-89f126d288d1", "age": 15, "created_at": "2026-04-27T21:32:56.116411+05:30", "updated_at": "2026-08-06T20:32:21.228095+05:30"}, {"uu": "7bb86a6e-a2ce-4c3c-9c3e-ef6593972638", "age": 10, "created_at": "2026-05-13T19:43:37.199779+05:30", "updated_at": "2026-07-20T07:43:02.372175+05:30"}, {"uu": "0dfbf0b2-d3c4-49b0-925c-0be170aa9669", "age": 9, "created_at": "2026-05-22T10:12:56.497206+05:30", "updated_at": "2026-07-21T06:58:47.901704+05:30"}, {"uu": "d83fd9d6-f88d-4e6e-86de-b80de6e0b443", "age": 7, "created_at": "2026-05-25T19:50:02.611928+05:30", "updated_at": "2026-07-31T19:15:42.159933+05:30"}, {"uu": "2fc84484-1388-4f07-9aa4-cd2211bc41b0", "age": 9, "created_at": "2026-05-29T08:25:18.030955+05:30", "updated_at": "2026-08-03T17:26:30.753996+05:30"}, {"uu": "3b658c52-3f18-436f-b220-c73610dffe2c", "age": 10, "created_at": "2026-04-27T20:18:20.973+05:30", "updated_at": "2026-08-06T20:28:14.638784+05:30"}, {"uu": "339908b7-3003-4dcd-a768-edad15ffe8e1", "age": 7, "created_at": "2026-07-03T19:58:07.606573+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "ca6d2d71-6d81-42be-8bf5-a768889522b0", "age": 10, "created_at": "2026-04-27T19:23:06.662418+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "a0ab2db6-bfa2-4dfb-9ebb-29c092ed8dfa", "age": 15, "created_at": "2026-05-22T10:17:03.601955+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "9e71781a-512a-43fd-b681-164a167263fb", "age": 7, "created_at": "2026-05-02T16:15:53.728031+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "45604117-16f4-4438-9c19-902eccfb9242", "age": 7, "created_at": "2026-05-02T17:06:56.649308+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "43ea8657-c182-4a8a-bfe4-afcb9ee864b1", "age": 6, "created_at": "2026-05-25T20:03:45.581853+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "00a63633-a5f5-426d-b334-c5f7e78f3568", "age": 9, "created_at": "2026-05-11T08:51:22.696852+05:30", "updated_at": "2026-07-16T11:00:47.539984+05:30"}, {"uu": "5ecfb823-12f5-427d-b529-d94827917446", "age": 5, "created_at": "2026-05-13T08:17:33.661993+05:30", "updated_at": "2026-07-16T18:59:23.145494+05:30"}, {"uu": "8cbed61e-0ec6-46c0-b1af-2e2991c070cb", "age": 10, "created_at": "2026-05-12T09:17:43.233667+05:30", "updated_at": "2026-07-16T16:00:25.002805+05:30"}, {"uu": "b64cc08a-3bb0-426e-8dc5-f172024ffea2", "age": 11, "created_at": "2026-06-18T07:35:40.707845+05:30", "updated_at": "2026-07-16T18:54:02.228563+05:30"}, {"uu": "2ef1c223-da36-4856-a7d0-37132f2accc5", "age": 10, "created_at": "2026-05-13T09:54:27.864008+05:30", "updated_at": "2026-07-16T22:01:28.401186+05:30"}, {"uu": "7265ad72-c6f6-459f-ab8b-3fe61bbea4c9", "age": 11, "created_at": "2026-06-23T11:04:29.504689+05:30", "updated_at": "2026-07-21T16:48:50.443598+05:30"}, {"uu": "06323cba-d2f3-4061-bd6a-83dc21c0e908", "age": 6, "created_at": "2026-05-29T08:52:48.930422+05:30", "updated_at": "2026-07-22T09:52:28.728184+05:30"}, {"uu": "0d14f40c-0b47-4730-88bc-454c1ce40092", "age": 9, "created_at": "2026-04-27T20:35:30.22853+05:30", "updated_at": "2026-08-10T15:21:09.984796+05:30"}, {"uu": "4e28f460-a199-449d-8dc7-60ad0aae528d", "age": 5, "created_at": "2026-05-02T16:52:42.995899+05:30", "updated_at": "2026-07-24T23:41:51.598415+05:30"}, {"uu": "62d79915-ddc6-4120-b546-436c9fe7a7e1", "age": 12, "created_at": "2026-05-02T17:43:58.714862+05:30", "updated_at": "2026-07-29T17:24:07.615633+05:30"}, {"uu": "53e7029c-756b-4c22-9ccb-0952dc26e508", "age": 12, "created_at": "2026-05-02T16:31:59.830003+05:30", "updated_at": "2026-08-01T20:38:11.692475+05:30"}, {"uu": "09564c87-0f87-4ffa-93d7-07744cd9f825", "age": 6, "created_at": "2026-05-02T16:27:03.561076+05:30", "updated_at": "2026-08-06T20:24:19.146934+05:30"}, {"uu": "5e43be78-1aaf-4c74-8963-572a4e472bb8", "age": 7, "created_at": "2026-08-06T19:47:56.581727+05:30", "updated_at": "2026-08-06T19:48:18.00974+05:30"}, {"uu": "af870993-1079-4a3d-bf89-a8eed1db0030", "age": 7, "created_at": "2026-05-02T17:02:53.616704+05:30", "updated_at": "2026-08-09T22:25:25.220885+05:30"}, {"uu": "fa013b4d-67c8-4bc1-9bfc-be462bfbd9fc", "age": 14, "created_at": "2026-07-21T16:55:17.016617+05:30", "updated_at": "2026-08-09T22:26:35.461806+05:30"}]'::jsonb) x
 where d.legacy_uuid = (x->>'uu')::uuid;

-- CREATE OR REPLACE cannot reorder or rename view columns, and this
-- rewrite does both. Dropping and recreating inside the migration's
-- transaction means the app never observes a missing view.
drop view if exists genalpha.students;
create view genalpha.students
with (security_invoker = true) as
select d.legacy_uuid                     as id,
       m.name,
       -- GenAlpha stores age directly and has no dob; deriving it from a
       -- null dob returned 0 for every student.
       coalesce(d.age, extract(year from age(m.dob))::int) as age,
       m.joined                          as join_date,
       d.fees_paid, d.amount_paid, d.renewals,
       coalesce(d.source_created_at, m.created_at) as created_at,
       coalesce(d.source_updated_at, m.updated_at) as updated_at,
       -- these live on members since 2026-08-10q, not on the side table
       m.added_by, m.updated_by, m.reg_no, m.rejoined_at,
       (m.status = 'discontinued')       as discontinued,
       m.discontinued_on                 as discontinued_at,
       d.time_slot, d.admission_id, d.jersey_size, d.jersey_pairs,
       d.payment_method, d.payment_upi_id, d.payment_reference,
       m.notes                           as comments,
       m.parent_name                     as father_guardian_name,
       m.parent_phone                    as parent_contact_no,
       m.alt_phone                       as alternate_contact_no,
       m.school                          as school_college,
       m.grade, m.address,
       d.filled_by, d.payment_status, d.fee_plan, d.coaching_fee,
       d.admission_fee, d.jersey_amount, d.total_fee_amount,
       d.fee_pause_days,
       m.whatsapp_status                 as whatsapp_contact_status,
       -- the three the app reads for its reminder logic. Missing entirely
       -- before this migration, which is what broke dues.
       m.reminders_paused                as whatsapp_reminders_paused,
       m.reminders_paused_at             as whatsapp_reminders_paused_at,
       m.reminders_paused_by             as whatsapp_reminders_paused_by,
       e.renewal_on                      as paid_through
  from public.members m
  join genalpha.student_details d on d.member_id = m.id
  left join public.enrollments e on e.member_id = m.id and e.tenant_id = 'genalpha'
 where m.tenant_id = 'genalpha';

grant select on genalpha.students to authenticated, service_role;

do $$
declare n int;
begin
  select count(*) into n from genalpha.students;
  if n <> 81 then raise exception 'view shows % students, expected 81', n; end if;

  -- the columns that were NULL must now be populated
  select count(*) into n from genalpha.students where reg_no is null;
  if n > 0 then raise exception '% students still have a null reg_no', n; end if;
  select count(*) into n from genalpha.students where added_by is null;
  if n > 0 then raise exception '% students still have a null added_by', n; end if;
  select count(*) into n from genalpha.students where age is null or age = 0;
  if n > 0 then raise exception '% students still have age 0 or null', n; end if;

  -- the trio the app needs must exist and be non-null
  if exists (select 1 from genalpha.students where whatsapp_reminders_paused is null) then
    raise exception 'whatsapp_reminders_paused is null — the app reads this for dues';
  end if;

  -- security_invoker must survive the rewrite or the view bypasses RLS
  if not coalesce((select option_value::boolean
                     from pg_class c join pg_namespace ns on ns.oid=c.relnamespace,
                          pg_options_to_table(c.reloptions)
                    where ns.nspname='genalpha' and c.relname='students'
                      and option_name='security_invoker'), false) then
    raise exception 'genalpha.students is no longer security_invoker';
  end if;

  raise notice 'view faithful again: reg_no, added_by, age, timestamps and the reminder trio all present';
end $$;
