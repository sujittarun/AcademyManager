-- ============================================================
-- 2026-08-11zp · The diagnostic that could not be written
-- scope: shared
--
-- Today's first live batch fell back from the direct-pay template to the
-- three old ladder templates, and the reason is unknown — because the
-- code path that records the reason cannot write.
--
-- When the direct-pay send fails with a template-class error, the engine
-- logs a whatsapp_flow_events row carrying event_type
-- 'direct_payment_template_fallback' with the provider's error code,
-- message and full payload. That insert throws, and
-- insertWhatsappFlowEvent() swallows its own errors by design:
--
--     catch (_error) {
--       // Timeline logging must never block the parent or manager
--       // payment flow.
--     }
--
-- So the send falls back, the family gets the wrong template, and the
-- explanation is discarded. Zero flow events exist for today despite 13
-- reminders going out.
--
-- The throw is 2026-08-11zf's blind spot. That migration retyped
-- reminder_event_id from uuid to bigint on payment_link_requests and
-- whatsapp_webhook_events, and missed the same column on
-- wa_flow_event_details — where it holds the reminder id the engine now
-- passes as a bigint-as-text. Reproduced directly:
--
--     column "reminder_event_id" is of type uuid but expression is of
--     type text
--
-- payment_link_request_id on the same table has the same problem and is
-- fixed with it: genalpha.payment_link_requests.id is still a uuid, so
-- that one stays uuid, but it is asserted rather than assumed.
-- ============================================================

-- ------------------------------------------------------------
-- Remap first, then retype. The 2,923 existing rows reference reminders
-- by their pre-merge uuid, and `alter ... type bigint` on those fails
-- outright — which is the honest failure, but not the useful one. All 502
-- distinct uuids resolve through the archive on created_at, the same join
-- that carried 2026-08-11zf, so nothing is discarded.
-- ------------------------------------------------------------
create temporary table _fu_map (legacy uuid primary key, ts timestamptz) on commit drop;
insert into _fu_map (legacy, ts) values
    ('32c27f86-e26a-4aee-b6a5-45814e4e8d42'::uuid,'2026-05-16T15:00:04.825742+05:30'::timestamptz),
    ('0ebcf8d9-8a76-4b3f-af94-8387e458aba0'::uuid,'2026-06-25T15:00:01.923211+05:30'::timestamptz),
    ('836a987d-d37d-43cd-8392-56a28b51e24e'::uuid,'2026-06-29T15:00:03.094877+05:30'::timestamptz),
    ('22e0a484-6db4-4bd2-ba73-7c683b6d2a89'::uuid,'2026-06-13T15:00:03.944256+05:30'::timestamptz),
    ('c3e91de3-a305-4a17-8ccf-05d6b82f4ede'::uuid,'2026-06-04T15:00:02.033606+05:30'::timestamptz),
    ('61637f26-7019-4572-8370-89b22ec2b45c'::uuid,'2026-07-16T15:00:03.556951+05:30'::timestamptz),
    ('e2c17422-6fe8-4dfc-9b6d-a956e8fd0e62'::uuid,'2026-05-21T15:00:02.098698+05:30'::timestamptz),
    ('59fb05e1-70fd-460a-917e-5c1aff7465c3'::uuid,'2026-08-04T15:00:00.837915+05:30'::timestamptz),
    ('85073f1d-c796-43c7-98c8-fac22fe4cd7e'::uuid,'2026-07-19T15:00:01.633279+05:30'::timestamptz),
    ('3ed52bfc-39d7-46b2-a2a1-a6089d33fad6'::uuid,'2026-06-13T15:00:03.349308+05:30'::timestamptz),
    ('7cd6dc1d-07a2-46dd-86b3-7101859f2510'::uuid,'2026-07-16T15:00:02.747118+05:30'::timestamptz),
    ('c3ab9cf5-ff14-46fa-84fb-3ca024bc32e9'::uuid,'2026-06-06T15:00:03.538519+05:30'::timestamptz),
    ('56b8ed76-9576-42d9-8005-86dfa3172dfa'::uuid,'2026-07-20T15:00:01.407891+05:30'::timestamptz),
    ('616b1d41-9af3-4eb6-8bd5-318a8fc3d62d'::uuid,'2026-05-25T15:00:02.767755+05:30'::timestamptz),
    ('04a02937-2944-440c-9bb1-9093e615b868'::uuid,'2026-06-28T15:00:02.891892+05:30'::timestamptz),
    ('47986013-a687-4924-b68d-1feffafbfc74'::uuid,'2026-06-16T15:00:01.761769+05:30'::timestamptz),
    ('96f66cbc-01be-45f5-8413-df0993e1bd67'::uuid,'2026-06-09T15:00:02.32684+05:30'::timestamptz),
    ('c4aa0489-0d3d-4692-b56f-c617f7d0b617'::uuid,'2026-08-07T15:00:01.510987+05:30'::timestamptz),
    ('faae97e5-acae-4ae6-bb46-6a1d1ccdc08b'::uuid,'2026-08-09T15:00:02.676411+05:30'::timestamptz),
    ('2da92e48-ca41-4037-9804-01bdb21e12ec'::uuid,'2026-07-21T15:00:01.930656+05:30'::timestamptz),
    ('a598623a-8055-41ff-ace6-5d9eb91fa2e0'::uuid,'2026-05-18T15:00:02.618204+05:30'::timestamptz),
    ('f87524bc-a45b-44e5-8daa-fcd2e87a20d4'::uuid,'2026-07-06T15:00:03.791239+05:30'::timestamptz),
    ('14488f45-8651-43d2-a6a2-d95518116588'::uuid,'2026-05-30T15:00:03.892633+05:30'::timestamptz),
    ('8ddd35b7-d98c-405e-8361-22fd300e8866'::uuid,'2026-06-29T15:00:02.261576+05:30'::timestamptz),
    ('98892410-49e5-4b01-8dbf-f6c54cd0c2b6'::uuid,'2026-05-31T15:00:03.108379+05:30'::timestamptz),
    ('47fd203a-bfe5-4e08-873f-84fa04037726'::uuid,'2026-06-06T15:00:02.118613+05:30'::timestamptz),
    ('7ba1b228-152a-4a9d-887c-2d734aa48302'::uuid,'2026-05-30T15:00:04.093316+05:30'::timestamptz),
    ('84cf8153-add3-4a52-a784-1221b8d5353a'::uuid,'2026-06-28T15:00:03.531618+05:30'::timestamptz),
    ('3c2448f0-5cc0-4af5-ba52-0c482527ece3'::uuid,'2026-07-12T15:00:02.248918+05:30'::timestamptz),
    ('b836695c-6f87-4e80-a4dc-9d0de3b3c29a'::uuid,'2026-07-10T15:00:02.282281+05:30'::timestamptz),
    ('967dc14a-5559-44df-8aef-c8d0d29a1131'::uuid,'2026-06-14T15:00:02.47906+05:30'::timestamptz),
    ('0c00cf38-9590-400a-9834-49f201d38eb1'::uuid,'2026-06-20T15:00:02.325081+05:30'::timestamptz),
    ('c22647d7-d160-4609-bb66-3296570ef6d8'::uuid,'2026-07-11T15:00:04.237684+05:30'::timestamptz),
    ('cdd822aa-9dd4-4487-a746-262e01e41669'::uuid,'2026-07-30T15:00:01.003399+05:30'::timestamptz),
    ('0e981ed4-d18e-422b-8e60-4475f09ef7f5'::uuid,'2026-05-27T15:00:03.393296+05:30'::timestamptz),
    ('7f3dbc14-c1c9-42bf-b9e0-e2a7f3804faa'::uuid,'2026-05-26T15:00:02.504431+05:30'::timestamptz),
    ('a619807d-ed1f-43d6-983d-07c9781c2895'::uuid,'2026-07-14T15:00:02.507894+05:30'::timestamptz),
    ('3369c94e-c328-44e5-a065-b8f72360bebf'::uuid,'2026-06-23T15:00:02.590528+05:30'::timestamptz),
    ('db901ae4-976a-440c-8866-ab185a58d322'::uuid,'2026-05-18T15:00:02.423845+05:30'::timestamptz),
    ('42c686af-cdf5-45fb-8464-afa6b7278e41'::uuid,'2026-06-21T15:00:01.816687+05:30'::timestamptz),
    ('60f48a81-9e9d-4a2c-833e-0ce352ac7ff1'::uuid,'2026-05-25T15:00:02.569795+05:30'::timestamptz),
    ('1277d039-d415-4ccf-8c30-d84d8a97824b'::uuid,'2026-06-29T15:00:02.46062+05:30'::timestamptz),
    ('6873244a-a084-4e3c-acc2-1ca14eb15a5f'::uuid,'2026-06-11T15:00:03.461428+05:30'::timestamptz),
    ('a874f8c8-b9c7-4271-a19a-f4ff17d5ab4e'::uuid,'2026-06-06T15:00:01.311899+05:30'::timestamptz),
    ('f8a2844b-0937-49dd-862b-1b6e6511efb3'::uuid,'2026-06-04T15:00:03.85702+05:30'::timestamptz),
    ('8dc59b3b-adec-4830-b1a4-a4b288515cfc'::uuid,'2026-07-29T15:00:01.530745+05:30'::timestamptz),
    ('6e29a1b9-472d-4a40-a393-1d72501161c6'::uuid,'2026-06-25T15:00:01.721891+05:30'::timestamptz),
    ('dd5781e4-c376-43a5-9a0f-6e13f8e41d3f'::uuid,'2026-08-06T15:00:01.843106+05:30'::timestamptz),
    ('cd2e3f24-d7b1-4c52-be5c-e0b53496be18'::uuid,'2026-07-04T15:00:02.629957+05:30'::timestamptz),
    ('b95bfeae-749c-4b6c-9e04-361b073a8516'::uuid,'2026-07-23T15:00:01.645879+05:30'::timestamptz),
    ('60662fab-f118-4da5-a684-b307a1533edb'::uuid,'2026-06-19T15:00:02.494435+05:30'::timestamptz),
    ('d43c6b37-b58c-4243-a87a-1e719799e3ef'::uuid,'2026-06-08T15:00:03.144683+05:30'::timestamptz),
    ('ca05455d-ae00-407a-8621-19f8069a4004'::uuid,'2026-06-09T15:00:01.510221+05:30'::timestamptz),
    ('5d0996cc-3f81-46d8-a9d5-d8f45b0c3089'::uuid,'2026-06-01T15:00:02.73566+05:30'::timestamptz),
    ('d363ad02-0574-4e45-b334-fc505c965850'::uuid,'2026-07-05T15:00:02.326897+05:30'::timestamptz),
    ('d485863e-c7b9-4905-963e-d83e3c6aa55a'::uuid,'2026-07-07T15:00:02.36319+05:30'::timestamptz),
    ('72af078a-2cca-4c82-b393-371124794fcb'::uuid,'2026-05-28T15:00:03.054694+05:30'::timestamptz),
    ('97a1e409-ce5c-439e-a09a-71cf9c069ed2'::uuid,'2026-07-18T15:00:01.694688+05:30'::timestamptz),
    ('6fd29141-ae86-4783-8d03-841b415007c1'::uuid,'2026-06-30T15:00:03.120789+05:30'::timestamptz),
    ('b727906d-bb9b-4bb1-acd4-b3234d68faa4'::uuid,'2026-06-07T15:00:02.402959+05:30'::timestamptz),
    ('28c98861-e7ab-4e13-ad2b-0709df2b5d7e'::uuid,'2026-08-07T15:00:01.298487+05:30'::timestamptz),
    ('9f4b8470-9bf2-4ea9-8a0d-ba0125bbd42b'::uuid,'2026-06-14T15:00:03.117192+05:30'::timestamptz),
    ('2230c5a7-87b0-4c47-a2da-05c074fb9ff6'::uuid,'2026-07-01T15:00:02.72964+05:30'::timestamptz),
    ('9ecee956-2be3-453c-ae4e-c85baec14171'::uuid,'2026-06-13T15:00:03.74913+05:30'::timestamptz),
    ('e0010ff4-62a5-4bb9-bcb2-c53d4c929982'::uuid,'2026-07-23T15:00:00.813029+05:30'::timestamptz),
    ('04ca1cd4-17b6-48f7-8e36-69ae60c0e200'::uuid,'2026-07-21T15:00:01.522617+05:30'::timestamptz),
    ('649e7f2e-32cf-4203-8030-6184421aac54'::uuid,'2026-07-05T15:00:02.096092+05:30'::timestamptz),
    ('0d5f75bd-6ea2-46c8-8a03-b88baa68a3ef'::uuid,'2026-08-09T15:00:01.826782+05:30'::timestamptz),
    ('36809835-bd1b-4089-8fc0-adf9c2471480'::uuid,'2026-05-19T15:00:02.628865+05:30'::timestamptz),
    ('4f16b37a-4d9d-4f01-a04a-8bb7cb3fc80d'::uuid,'2026-06-12T15:00:01.822462+05:30'::timestamptz),
    ('0e3e6e72-8f13-4b29-a545-7ce3ff16d3d9'::uuid,'2026-07-16T15:00:03.76202+05:30'::timestamptz),
    ('8658f723-eeac-4e0f-a5c4-d78181078e5d'::uuid,'2026-05-23T15:00:02.642348+05:30'::timestamptz),
    ('701fe780-97ed-4838-aeb2-88b2353729a2'::uuid,'2026-06-21T15:00:02.500288+05:30'::timestamptz),
    ('9af800de-a756-4c6a-a3e6-19dfbddef410'::uuid,'2026-05-16T15:00:04.62416+05:30'::timestamptz),
    ('a3e5a96a-9776-4fe3-9e5d-68d71966c9a0'::uuid,'2026-06-30T15:00:02.045061+05:30'::timestamptz),
    ('85a5f02f-fda1-48f2-9c20-7f61b514f9cd'::uuid,'2026-05-17T15:00:02.90895+05:30'::timestamptz),
    ('34c7b98e-c5f7-4abc-b484-d4beb6f9cf7b'::uuid,'2026-06-13T15:00:03.132387+05:30'::timestamptz),
    ('774225f7-13ea-4677-8b99-d8e2a5a58519'::uuid,'2026-06-25T15:00:02.323868+05:30'::timestamptz),
    ('f527d232-268c-48ad-8195-f714e842b25e'::uuid,'2026-07-21T15:00:01.075511+05:30'::timestamptz),
    ('d3fd6972-d45c-40ee-8914-d501cb1e73ae'::uuid,'2026-05-21T15:00:02.702773+05:30'::timestamptz),
    ('4cdf6042-d2eb-4c20-83b1-38fe048ae3b9'::uuid,'2026-08-09T15:00:03.10704+05:30'::timestamptz),
    ('5397283e-195b-4271-b3a6-91f331d0e069'::uuid,'2026-06-23T15:00:01.952687+05:30'::timestamptz),
    ('977dd81f-130e-4ee5-adf8-b268baf940ff'::uuid,'2026-07-06T15:00:03.590719+05:30'::timestamptz),
    ('4848029f-d213-4285-8a67-b4e4b6f7108a'::uuid,'2026-07-06T15:00:03.387267+05:30'::timestamptz),
    ('9c4e2c9b-60c8-46b6-acd2-451d626db11c'::uuid,'2026-06-11T15:00:03.185343+05:30'::timestamptz),
    ('ff8a47c6-71f2-46e4-a888-c465e2d4f6bb'::uuid,'2026-06-02T15:00:02.257085+05:30'::timestamptz),
    ('1b7d9563-79aa-4634-958f-274fa9c2bff2'::uuid,'2026-06-06T15:00:02.924671+05:30'::timestamptz),
    ('e1d375b4-eaa4-4227-b979-a8837caa8d2b'::uuid,'2026-07-14T15:00:01.876095+05:30'::timestamptz),
    ('e73d6ddc-d0a3-4733-9f0e-efc82b30f203'::uuid,'2026-05-18T15:00:03.012032+05:30'::timestamptz),
    ('0c02c6dd-cb4a-407b-b256-e4bca6ff42e8'::uuid,'2026-08-06T15:00:02.690767+05:30'::timestamptz),
    ('947ebb16-c2cd-4ed9-96c6-8754233ff7e7'::uuid,'2026-05-16T15:00:04.422256+05:30'::timestamptz),
    ('39ac7b88-8976-4b00-8bed-d7c7ffe3e0b4'::uuid,'2026-07-11T15:00:03.428825+05:30'::timestamptz),
    ('b2fe94b2-d8d2-422c-b208-09e449182976'::uuid,'2026-06-22T15:00:02.814814+05:30'::timestamptz),
    ('8c81182f-e25f-437a-87fa-0a37c1c5f840'::uuid,'2026-06-04T15:00:01.829726+05:30'::timestamptz),
    ('d30d5336-5238-4afe-bf8c-f1ff3321d546'::uuid,'2026-07-15T15:00:02.335484+05:30'::timestamptz),
    ('a199338d-9cc2-4dba-8501-507f08f17ddc'::uuid,'2026-07-25T15:00:01.334904+05:30'::timestamptz),
    ('fb0504df-6241-49c8-83dc-197dfb1a8174'::uuid,'2026-06-16T15:00:02.409091+05:30'::timestamptz),
    ('a58fe497-7adc-48eb-b17d-29439ccd3eb5'::uuid,'2026-08-09T15:00:01.403433+05:30'::timestamptz),
    ('f7689278-274d-47f7-8403-b24d41f1b93f'::uuid,'2026-05-20T15:00:03.002457+05:30'::timestamptz),
    ('b2214848-6559-4bc7-83a1-c66fa7ed6c69'::uuid,'2026-06-01T15:00:03.351092+05:30'::timestamptz),
    ('291abfb1-471e-4284-a5d9-f32560b2d27d'::uuid,'2026-08-09T15:00:02.871569+05:30'::timestamptz),
    ('57991d64-311c-403a-9971-e8637cb791cd'::uuid,'2026-05-17T15:00:03.524179+05:30'::timestamptz),
    ('1702c75b-94c9-484f-a2be-c41d7e35103b'::uuid,'2026-07-08T15:00:02.656543+05:30'::timestamptz),
    ('4614d725-f911-4926-a0eb-7d5f6aab104c'::uuid,'2026-05-30T15:00:03.286775+05:30'::timestamptz),
    ('ea0baf05-dd45-4062-ba43-033c0dd2108a'::uuid,'2026-06-29T15:00:03.298748+05:30'::timestamptz),
    ('401da1b1-2e06-4ae7-87c5-7784965eb670'::uuid,'2026-07-16T15:00:03.355178+05:30'::timestamptz),
    ('f9548ab7-3bab-4a01-92d2-e2ae37285b88'::uuid,'2026-06-15T15:00:01.888707+05:30'::timestamptz),
    ('4c574845-d9c5-4178-9206-3f2bef3fe062'::uuid,'2026-07-02T15:00:02.334439+05:30'::timestamptz),
    ('c8845723-b9ed-4739-94b0-ea6101ff3add'::uuid,'2026-05-23T15:00:03.048187+05:30'::timestamptz),
    ('48067ed5-a551-487c-85ad-1e6acee6a00f'::uuid,'2026-05-20T15:00:03.20391+05:30'::timestamptz),
    ('53fadacd-4600-4f66-af72-ab82c9e27f6e'::uuid,'2026-07-03T15:00:07.258337+05:30'::timestamptz),
    ('66c276ca-dff4-46f6-a51b-05b264399b03'::uuid,'2026-05-20T15:00:02.398397+05:30'::timestamptz),
    ('d19c46bf-225e-4ce4-844c-132c22a7a75e'::uuid,'2026-05-24T15:00:03.736749+05:30'::timestamptz),
    ('69400a6d-4325-4c90-a8d5-1c8138e50d25'::uuid,'2026-06-08T15:00:02.131827+05:30'::timestamptz),
    ('49c909b3-89e1-4a31-8a60-ddb6c1875697'::uuid,'2026-07-06T15:00:03.165831+05:30'::timestamptz),
    ('10cf9811-b85f-43cc-9005-3f325d7abdcb'::uuid,'2026-06-26T15:00:02.271967+05:30'::timestamptz),
    ('1d6ae31b-9fc3-4537-9cbc-7ff16bcbaaa0'::uuid,'2026-06-27T15:00:03.030412+05:30'::timestamptz),
    ('6a87da69-96c8-4a18-a4be-5c0b45bd97a8'::uuid,'2026-06-23T15:00:02.155052+05:30'::timestamptz),
    ('41421919-311e-469f-8c19-544c16bf6483'::uuid,'2026-06-04T15:00:02.642768+05:30'::timestamptz),
    ('78d67542-6c3f-4c0f-a781-e4031df669d8'::uuid,'2026-07-12T15:00:01.827314+05:30'::timestamptz),
    ('b7199916-cc08-491a-9bdb-3161d51bbb46'::uuid,'2026-05-17T15:00:03.31111+05:30'::timestamptz),
    ('1b87ae49-ba95-4079-8631-78478831d392'::uuid,'2026-06-09T15:00:01.312161+05:30'::timestamptz),
    ('1e37539e-269b-455f-9b2f-7a39b7885255'::uuid,'2026-05-16T15:00:03.818679+05:30'::timestamptz),
    ('0b5b8ff2-4552-4946-a9e5-17e4c9669bc2'::uuid,'2026-07-23T15:00:01.250532+05:30'::timestamptz),
    ('436f4386-d4f9-4559-86d5-92bc615e35f3'::uuid,'2026-05-31T15:00:03.319106+05:30'::timestamptz),
    ('b535a7e4-ed54-4124-aa84-6d331b0cb146'::uuid,'2026-07-21T15:00:01.726781+05:30'::timestamptz),
    ('eaebb1fa-ca4f-4b00-954f-9b56e30813f7'::uuid,'2026-06-05T15:00:03.115083+05:30'::timestamptz),
    ('45feae6d-c684-4de4-8cf1-a67fd7f84e72'::uuid,'2026-06-07T15:00:03.035886+05:30'::timestamptz),
    ('bdaf5d16-4ebb-448a-90b0-59da909957b1'::uuid,'2026-07-05T15:00:02.530689+05:30'::timestamptz),
    ('7a2a8e44-fba7-4707-bf42-ebe691ab26f8'::uuid,'2026-07-22T15:00:01.848452+05:30'::timestamptz),
    ('899c77c7-c24a-47c1-8fbe-c8bd44880ca1'::uuid,'2026-06-27T15:00:03.462879+05:30'::timestamptz),
    ('0bdea3e1-3032-4203-9797-c3062e4fa779'::uuid,'2026-07-31T15:00:01.348099+05:30'::timestamptz),
    ('29af2fc1-39aa-4db2-be83-6cfd0b57db55'::uuid,'2026-07-09T15:00:04.030997+05:30'::timestamptz),
    ('676764e8-635c-4bb8-8cc7-9f75ea21522b'::uuid,'2026-07-04T15:00:03.432509+05:30'::timestamptz),
    ('1a881c95-b1b3-492d-8f8d-d09c4a8bec12'::uuid,'2026-06-01T15:00:02.932942+05:30'::timestamptz),
    ('adb96c85-fa8e-4422-b079-1d72c4a8f3b4'::uuid,'2026-07-18T15:00:01.050463+05:30'::timestamptz),
    ('6e8f69c8-861b-4b3d-a4bf-43b1342dea89'::uuid,'2026-06-11T15:00:01.848195+05:30'::timestamptz),
    ('66ee2f02-b817-4728-8616-a9096ecf4aee'::uuid,'2026-05-24T15:00:03.920591+05:30'::timestamptz),
    ('56e55c92-7d74-46ff-b9a0-aaa7de1f1006'::uuid,'2026-06-30T15:00:02.714505+05:30'::timestamptz),
    ('a539aa9f-4f64-4f41-a0da-579f179fee38'::uuid,'2026-07-26T15:00:01.371972+05:30'::timestamptz),
    ('3e574707-0371-4e16-b6d2-842bd5cddec0'::uuid,'2026-06-18T15:00:02.307782+05:30'::timestamptz),
    ('71c7b59c-2bea-4878-83eb-4524aa06a0ad'::uuid,'2026-05-22T15:00:03.39859+05:30'::timestamptz),
    ('9483143d-02cd-4777-90f8-b66d3161839a'::uuid,'2026-06-07T15:00:02.814807+05:30'::timestamptz),
    ('16f63b63-4365-43b6-a582-7aa1533f2bb1'::uuid,'2026-07-16T15:00:02.120425+05:30'::timestamptz),
    ('1694fe72-6f24-4694-8921-6ada4b83e917'::uuid,'2026-05-21T15:00:02.501545+05:30'::timestamptz),
    ('fcbc7658-169a-481b-ae04-82582c794f3e'::uuid,'2026-06-21T15:00:03.078707+05:30'::timestamptz),
    ('5cc30685-7e29-4134-9e01-0116fd5885c7'::uuid,'2026-06-06T15:00:01.712704+05:30'::timestamptz),
    ('3ec1b77a-5ec3-4b21-9973-0670dcd0e911'::uuid,'2026-05-27T15:00:02.805173+05:30'::timestamptz),
    ('5ee734f3-5a45-4c5e-9d1d-de7f54febd95'::uuid,'2026-05-18T15:00:03.210531+05:30'::timestamptz),
    ('972f5178-b531-4f02-ae82-f070ec6fe25b'::uuid,'2026-07-01T15:00:01.85758+05:30'::timestamptz),
    ('92566136-ad08-4129-8f10-71fb44a149e9'::uuid,'2026-06-06T15:00:02.31773+05:30'::timestamptz),
    ('9bb3ba59-8546-4939-a469-09cd3eca48fc'::uuid,'2026-05-17T15:00:02.509717+05:30'::timestamptz),
    ('5cff768b-6899-4eda-aafb-22bd47ad54e9'::uuid,'2026-06-27T15:00:02.624689+05:30'::timestamptz),
    ('60a61d5a-097f-4102-9082-c6e51989d1de'::uuid,'2026-07-16T15:00:02.950369+05:30'::timestamptz),
    ('39d676e7-8a11-4698-8847-afb01e1cc5c7'::uuid,'2026-06-18T15:00:02.738119+05:30'::timestamptz),
    ('713ab43e-f547-41f4-b2cc-587727669c99'::uuid,'2026-06-30T15:00:02.91751+05:30'::timestamptz),
    ('6c7f8b34-d660-4259-9e1c-1278081ba91e'::uuid,'2026-06-26T15:00:01.848363+05:30'::timestamptz),
    ('4da8e9e8-41e6-487a-bba6-772455777138'::uuid,'2026-06-05T15:00:02.478863+05:30'::timestamptz),
    ('3366c4ce-2cbf-4ce1-9870-41813f7d1d51'::uuid,'2026-07-20T15:00:01.006066+05:30'::timestamptz),
    ('f28948d3-1ea7-4aa7-9a9a-1fba6e3391de'::uuid,'2026-05-23T15:00:02.442699+05:30'::timestamptz),
    ('6c5f05da-d1a4-489e-a016-90ae3dc68202'::uuid,'2026-08-07T15:00:02.013839+05:30'::timestamptz),
    ('62279697-ec8f-40f6-98d2-9c81ea704d13'::uuid,'2026-07-07T15:00:01.962739+05:30'::timestamptz),
    ('8d12f728-2f55-40e4-88db-3b285e382e7c'::uuid,'2026-08-01T15:00:01.812357+05:30'::timestamptz),
    ('5b999fbd-b73f-400b-923b-defdee8cc990'::uuid,'2026-07-11T15:00:02.789803+05:30'::timestamptz),
    ('7be6f693-14b6-493a-b4bb-ee0b0b050f93'::uuid,'2026-06-11T15:00:04.283686+05:30'::timestamptz),
    ('60d487e5-6eeb-4390-8356-29479f8c5d2c'::uuid,'2026-06-19T15:00:02.027601+05:30'::timestamptz),
    ('df63b624-a9f3-43be-9817-93d71c947cb4'::uuid,'2026-08-09T15:00:03.329858+05:30'::timestamptz),
    ('99542a4d-9e82-4525-a617-5edfa1c4b96d'::uuid,'2026-08-04T15:00:01.250863+05:30'::timestamptz),
    ('ba535b56-df08-49fb-974b-b0feda82b2c3'::uuid,'2026-08-09T15:00:02.446725+05:30'::timestamptz),
    ('1b404c93-77a9-44f5-ba36-ecbdc8f1f50f'::uuid,'2026-07-11T15:00:04.441917+05:30'::timestamptz),
    ('f9ace9e2-5c39-42dd-afcf-246e37c5c347'::uuid,'2026-07-14T15:00:02.304476+05:30'::timestamptz),
    ('6458072e-9651-4d7f-a571-98f0fcf87a51'::uuid,'2026-07-14T15:00:02.075695+05:30'::timestamptz),
    ('180b5632-b15b-4fc5-989c-e0efed8d138b'::uuid,'2026-05-29T15:00:02.735605+05:30'::timestamptz),
    ('e8bdc733-7447-4f49-9d86-072ab28317ca'::uuid,'2026-07-24T15:00:01.387069+05:30'::timestamptz),
    ('d22c9e13-8bbc-4ebf-9ade-88a32c0cee7c'::uuid,'2026-06-01T15:00:03.137672+05:30'::timestamptz),
    ('a5735e22-6566-4971-9f4f-b4cc195231f4'::uuid,'2026-07-30T15:00:01.84688+05:30'::timestamptz),
    ('d16cb1b4-067d-4a5c-8585-27fc18e34a9a'::uuid,'2026-07-29T15:00:01.733959+05:30'::timestamptz),
    ('e3ea0306-23d4-4f7b-93ab-d4a2de5b3f53'::uuid,'2026-06-22T15:00:02.150943+05:30'::timestamptz),
    ('3994a3d5-ec03-4a69-809d-d88b816336c2'::uuid,'2026-06-16T15:00:02.188861+05:30'::timestamptz),
    ('61ca5fd5-e7a8-490d-aab8-0777b51785f3'::uuid,'2026-06-04T15:00:03.049185+05:30'::timestamptz),
    ('bfd499f0-8c65-4d88-9a96-2d1abdb2f0bf'::uuid,'2026-07-09T15:00:02.795838+05:30'::timestamptz),
    ('6e0760e6-9849-46cf-8bb5-0efc3704d503'::uuid,'2026-07-28T15:00:01.573662+05:30'::timestamptz),
    ('1f1e6969-c16a-4398-b30f-163382ddde7d'::uuid,'2026-06-05T15:00:02.71192+05:30'::timestamptz),
    ('7610f025-fef0-46c3-a567-7095d570c170'::uuid,'2026-07-11T15:00:02.822385+05:30'::timestamptz),
    ('901b3a9c-0f9b-4741-82fc-22a2a3ed39cc'::uuid,'2026-06-07T15:00:02.002213+05:30'::timestamptz),
    ('e7306803-3d8c-47dc-9cd3-86493f2740be'::uuid,'2026-07-11T15:00:01.781828+05:30'::timestamptz),
    ('a605ee8d-4fe3-41ea-bd3b-c5a3b3a2b354'::uuid,'2026-05-28T15:00:03.458402+05:30'::timestamptz),
    ('91b9b965-1bfd-42a8-898e-771a184ad206'::uuid,'2026-07-11T15:00:01.981945+05:30'::timestamptz),
    ('77ce863b-528b-468a-b33c-e8c638f35af9'::uuid,'2026-08-04T15:00:01.055261+05:30'::timestamptz),
    ('6ca5d15b-70e4-4460-8bfb-58a2ad0f9fe8'::uuid,'2026-06-09T15:00:02.522595+05:30'::timestamptz),
    ('cfb5f37c-66cb-40bc-b9a9-95a2449587a9'::uuid,'2026-06-07T15:00:02.196607+05:30'::timestamptz),
    ('e159347a-2bb7-447b-a6b4-103b7619944c'::uuid,'2026-06-09T15:00:03.128583+05:30'::timestamptz),
    ('a772c0b8-69a1-4ceb-b83d-2cdd37e20f97'::uuid,'2026-08-09T15:00:00.770392+05:30'::timestamptz),
    ('d20e8d18-ead3-4017-854a-850efab120a4'::uuid,'2026-06-12T15:00:02.739747+05:30'::timestamptz),
    ('1af7dad0-6329-4db8-8cab-1526f3755c1b'::uuid,'2026-07-19T15:00:01.039013+05:30'::timestamptz),
    ('79d1835b-e707-47e6-8a17-7e9726fcb0cd'::uuid,'2026-07-24T15:00:01.78392+05:30'::timestamptz),
    ('dc75b934-6865-44a3-b3dd-8c2522676d09'::uuid,'2026-07-17T15:00:01.005903+05:30'::timestamptz),
    ('c27db476-727a-4035-9403-8810b15026f7'::uuid,'2026-07-05T15:00:03.375159+05:30'::timestamptz),
    ('7533feaa-2862-451b-b652-d341ac9c46bf'::uuid,'2026-05-20T15:00:02.19937+05:30'::timestamptz),
    ('445b76e6-2d20-48f5-a4b2-9560903d344d'::uuid,'2026-05-30T15:00:03.487604+05:30'::timestamptz),
    ('287cc41f-968e-430c-9d8a-2dc79d2b463a'::uuid,'2026-07-26T15:00:01.15877+05:30'::timestamptz),
    ('b8902eba-aea5-4a13-a045-4e9fceefd2cb'::uuid,'2026-06-27T15:00:03.681981+05:30'::timestamptz),
    ('f4e5281d-98f3-47b3-a19b-0350edc57c89'::uuid,'2026-07-20T15:00:01.60918+05:30'::timestamptz),
    ('04dc391f-6bfd-4847-9ea5-f6edf209872b'::uuid,'2026-08-07T15:00:02.216154+05:30'::timestamptz),
    ('3d6fae17-abc1-4a6d-b8fa-da3c687c712e'::uuid,'2026-07-05T15:00:03.189481+05:30'::timestamptz),
    ('3aa42649-9e60-446f-8c53-8991f889a072'::uuid,'2026-06-29T15:00:03.944403+05:30'::timestamptz),
    ('14d0011a-8143-4395-b40e-259e0a5e7aad'::uuid,'2026-07-09T15:00:02.99532+05:30'::timestamptz),
    ('ea61dac1-e93d-4496-b62b-39cf4965bf8b'::uuid,'2026-08-07T15:00:01.711437+05:30'::timestamptz),
    ('eb108200-274b-4250-b0bd-9aac78bd2a0b'::uuid,'2026-07-11T15:00:02.691564+05:30'::timestamptz),
    ('ff5299e6-7adc-4494-9674-7ade650d83ae'::uuid,'2026-06-07T15:00:02.602007+05:30'::timestamptz),
    ('5086dde6-a993-4be7-9519-f6d754ef64f2'::uuid,'2026-06-28T15:00:03.73022+05:30'::timestamptz),
    ('d805a74a-7edd-4776-8be4-4d6b68d08c4f'::uuid,'2026-07-06T15:00:02.765383+05:30'::timestamptz),
    ('354d84a5-3691-4c85-a157-0c7d7e408c97'::uuid,'2026-07-16T15:00:01.714382+05:30'::timestamptz),
    ('aab5790f-610f-4482-9526-bdb3225cb755'::uuid,'2026-05-16T15:00:04.223168+05:30'::timestamptz),
    ('60f0f89a-165d-4f00-96c3-66dc35b10b26'::uuid,'2026-06-22T15:00:02.618253+05:30'::timestamptz),
    ('209e32bc-f68f-48e2-b967-6853989a86c0'::uuid,'2026-06-26T15:00:02.039556+05:30'::timestamptz),
    ('23b1bab2-44a7-46a3-9bc9-a22e6542f1de'::uuid,'2026-07-13T15:00:03.165307+05:30'::timestamptz),
    ('7b244c0e-ec58-4e03-b3e2-48e48336f0b0'::uuid,'2026-07-06T15:00:04.020934+05:30'::timestamptz),
    ('b1fe8f0b-c452-4f81-9ce0-4a4d0df33180'::uuid,'2026-05-24T15:00:03.136842+05:30'::timestamptz),
    ('3b2e9d2b-acc6-4757-aa59-5d0cc966fb1d'::uuid,'2026-06-06T15:00:01.510747+05:30'::timestamptz),
    ('1ab75484-4f3d-44f7-b16b-a35190a771a9'::uuid,'2026-06-06T15:00:02.721968+05:30'::timestamptz),
    ('f8ccd90c-0fbf-447c-96c8-95a62ee033f1'::uuid,'2026-08-08T15:00:01.282886+05:30'::timestamptz),
    ('cbd31572-4289-4bed-a5cf-d20584741066'::uuid,'2026-05-24T15:00:03.51712+05:30'::timestamptz),
    ('b71049d4-1245-481b-9307-19a320f1d4ab'::uuid,'2026-07-31T15:00:01.101106+05:30'::timestamptz),
    ('8ade88f3-cf0d-4fb6-8267-09dd7a3bbfde'::uuid,'2026-06-24T15:00:02.218499+05:30'::timestamptz),
    ('bf7e3ed8-3b16-4b3a-8a96-813785ec9811'::uuid,'2026-05-19T15:00:04.048172+05:30'::timestamptz),
    ('ad697f1e-1580-48ba-9c9b-c7622d23b678'::uuid,'2026-07-11T15:00:03.62938+05:30'::timestamptz),
    ('6870638d-86a5-4e3b-9193-84de440968e0'::uuid,'2026-08-06T15:00:02.047036+05:30'::timestamptz),
    ('21ec1d9e-0b18-45ee-b700-6a817655d1be'::uuid,'2026-06-02T15:00:02.651495+05:30'::timestamptz),
    ('f6292bcd-c743-4d3e-a2fb-ab99a5490013'::uuid,'2026-05-25T15:00:01.761433+05:30'::timestamptz),
    ('865d7f3a-84d8-48b1-a80f-58951f587975'::uuid,'2026-07-04T15:00:02.207625+05:30'::timestamptz),
    ('ac321826-3007-439f-a103-a7f2cea25a8c'::uuid,'2026-06-15T15:00:02.08615+05:30'::timestamptz),
    ('d4361615-4fe5-4cc9-af32-1f2555626cf2'::uuid,'2026-06-07T15:00:03.419666+05:30'::timestamptz),
    ('97658b42-29ad-4c68-818f-5bd5dcd7334d'::uuid,'2026-06-23T15:00:01.724335+05:30'::timestamptz),
    ('5f9800ea-c5ed-4064-95c5-7c2d589ba5cc'::uuid,'2026-06-04T15:00:01.632654+05:30'::timestamptz),
    ('496f31bb-f1be-40b1-927d-a8b6ef5499b6'::uuid,'2026-07-04T15:00:03.249325+05:30'::timestamptz),
    ('64afadcf-6241-4dc9-a96f-03d7b6e4f09d'::uuid,'2026-08-09T15:00:01.62621+05:30'::timestamptz),
    ('1a8c3af8-2e57-421c-9a6e-d457f387d441'::uuid,'2026-05-25T15:00:02.968847+05:30'::timestamptz),
    ('5564fb58-c8b1-4ff1-89e0-13fc07105068'::uuid,'2026-06-09T15:00:02.117016+05:30'::timestamptz),
    ('0d27c13f-ef99-43b3-89e5-8a5f47fe7fdc'::uuid,'2026-05-19T15:00:03.634872+05:30'::timestamptz),
    ('2033981a-5a26-411f-afb4-8a2fd6052843'::uuid,'2026-06-14T15:00:03.525018+05:30'::timestamptz),
    ('55ebabd3-a4f8-4794-bd45-e12c6d185495'::uuid,'2026-07-01T15:00:02.506065+05:30'::timestamptz),
    ('b4be6ec1-5ae2-4e86-80c4-d2363eabc923'::uuid,'2026-05-30T15:00:02.690584+05:30'::timestamptz),
    ('7c62d0df-e583-4fcd-93a5-d6a4d4c92415'::uuid,'2026-06-21T15:00:02.660795+05:30'::timestamptz),
    ('6294800b-553b-4ef5-a087-b2c77e3b6e4a'::uuid,'2026-07-09T15:00:03.408745+05:30'::timestamptz),
    ('796c591e-127c-41cc-89e7-690538f614ce'::uuid,'2026-06-15T15:00:02.333575+05:30'::timestamptz),
    ('bb17a3dc-5bb7-460a-8404-1d183544bb75'::uuid,'2026-07-30T15:00:02.079118+05:30'::timestamptz),
    ('9b38ad58-d060-4afc-8df1-ff47c9e4cbde'::uuid,'2026-08-04T15:00:00.633014+05:30'::timestamptz),
    ('b4fe125c-fbf1-4faa-bb87-a87028b5d5c0'::uuid,'2026-07-09T15:00:03.198732+05:30'::timestamptz),
    ('3de8f6b1-97e4-4e48-9094-fbe423c9b472'::uuid,'2026-07-13T15:00:02.962125+05:30'::timestamptz),
    ('1b115823-12ce-433c-8089-f135208c3331'::uuid,'2026-07-10T15:00:02.748271+05:30'::timestamptz),
    ('1a570970-fd4a-498a-99f5-e6dca63a5ffc'::uuid,'2026-07-30T15:00:01.210849+05:30'::timestamptz),
    ('9ddec229-1026-48b5-b425-1add82eb3abf'::uuid,'2026-05-24T15:00:04.125076+05:30'::timestamptz),
    ('34b108e0-f705-4483-bd00-c0ccd52a315c'::uuid,'2026-07-13T15:00:02.761593+05:30'::timestamptz),
    ('a29c98cf-4147-4545-a267-05d8b8d3a528'::uuid,'2026-08-10T15:00:01.430523+05:30'::timestamptz),
    ('9eb10e62-e32a-4dd7-8acd-5ac1bed0eddd'::uuid,'2026-06-11T15:00:03.25692+05:30'::timestamptz),
    ('da420103-65d4-4c17-a63b-c39e951bad61'::uuid,'2026-05-20T15:00:02.599234+05:30'::timestamptz),
    ('f53a1f30-4700-4cdb-b3c3-34ad39eb2230'::uuid,'2026-08-08T15:00:01.747498+05:30'::timestamptz),
    ('2355c958-035c-4778-96ab-573e45624981'::uuid,'2026-07-20T15:00:02.088573+05:30'::timestamptz),
    ('76b093c8-4e1a-4d72-934a-74754304cfc6'::uuid,'2026-06-21T15:00:02.214785+05:30'::timestamptz),
    ('91cf5abf-6a5b-4ba4-8e05-e89c778df559'::uuid,'2026-06-03T15:00:01.915339+05:30'::timestamptz),
    ('4db9764a-b537-427d-908b-b6e5f71744c0'::uuid,'2026-06-26T15:00:02.67431+05:30'::timestamptz),
    ('eae22924-b816-4892-accc-929fb98d3bcd'::uuid,'2026-06-03T15:00:02.117605+05:30'::timestamptz),
    ('2353ac70-d9ff-490f-91c3-4a6795004bb0'::uuid,'2026-05-18T15:00:03.415658+05:30'::timestamptz),
    ('3b84df3f-a63e-481d-92c7-677dda835d91'::uuid,'2026-06-13T15:00:02.721174+05:30'::timestamptz),
    ('f04fce3f-a2a0-4194-9e70-7f38c0ca819c'::uuid,'2026-06-03T15:00:02.319663+05:30'::timestamptz),
    ('9d974d0a-d462-408a-b4ef-8f870ec8c309'::uuid,'2026-05-20T15:00:02.800717+05:30'::timestamptz),
    ('30b2de4f-9b66-49a1-8846-7e1ebfb08b13'::uuid,'2026-06-16T15:00:01.986376+05:30'::timestamptz),
    ('73e130d0-140a-41b6-8484-d4648cf91744'::uuid,'2026-07-08T15:00:02.859575+05:30'::timestamptz),
    ('37795fe0-f069-4634-b8ed-0ad72221fbc2'::uuid,'2026-05-21T15:00:02.903597+05:30'::timestamptz),
    ('d24649b1-058f-4e2e-87e6-89512d41bbba'::uuid,'2026-07-16T15:00:02.534663+05:30'::timestamptz),
    ('fd906ed8-025d-4a98-926d-959730f0fc9e'::uuid,'2026-07-20T15:00:01.879087+05:30'::timestamptz),
    ('b577a3aa-2abd-408b-95a7-f3d155a53aa6'::uuid,'2026-05-30T15:00:03.091204+05:30'::timestamptz),
    ('2f71dd8b-1de5-4ade-99a1-1e081888480f'::uuid,'2026-08-09T15:00:02.020884+05:30'::timestamptz),
    ('31786547-3416-4800-af50-ae7286a2bfcf'::uuid,'2026-07-07T15:00:02.161209+05:30'::timestamptz),
    ('860682b9-7154-4855-893c-de0216ab9d5d'::uuid,'2026-07-06T15:00:02.55823+05:30'::timestamptz),
    ('5f20b524-8ecf-4a97-968b-b29f005b1979'::uuid,'2026-07-15T15:00:02.132518+05:30'::timestamptz),
    ('e9a3aa1e-dff7-4a26-b623-9086e1c69583'::uuid,'2026-06-04T15:00:02.441689+05:30'::timestamptz),
    ('17013e83-654a-436a-af23-580534df724b'::uuid,'2026-08-09T15:00:03.735131+05:30'::timestamptz),
    ('b7e89916-578f-44c4-9aa8-b98e7c582827'::uuid,'2026-08-01T15:00:02.018996+05:30'::timestamptz),
    ('e50b71e6-34b7-4ea3-b2d5-704f2278dc7b'::uuid,'2026-08-08T15:00:00.880759+05:30'::timestamptz),
    ('23b76e07-bdcc-416b-bb26-d751a88ce387'::uuid,'2026-06-22T15:00:02.41098+05:30'::timestamptz),
    ('d309a5c3-dabf-41bb-b850-5ecd5e99ebcd'::uuid,'2026-07-21T15:00:00.876883+05:30'::timestamptz),
    ('85fcba7c-aa57-44c3-b3de-9e4cd5c30454'::uuid,'2026-08-06T15:00:01.383476+05:30'::timestamptz),
    ('ed4ef65a-c02a-48a8-9493-8e978272b7c6'::uuid,'2026-06-05T15:00:02.280161+05:30'::timestamptz),
    ('6d5cc707-baff-418e-a2f6-0b5a16e8a89e'::uuid,'2026-06-14T15:00:03.322049+05:30'::timestamptz),
    ('04ed59e9-f0fd-434c-b376-983c1608e6b5'::uuid,'2026-07-18T15:00:01.460427+05:30'::timestamptz),
    ('88cb4669-5b3c-44cb-874d-92f9368884b5'::uuid,'2026-05-31T15:00:02.888751+05:30'::timestamptz),
    ('8504b3db-a38a-4e6e-b08f-02b31306a1bc'::uuid,'2026-06-01T15:00:03.539943+05:30'::timestamptz),
    ('af546e92-2236-48b8-b65b-2759472af2e4'::uuid,'2026-07-19T15:00:01.772553+05:30'::timestamptz),
    ('7b268eb5-cabc-4073-9725-f6665ef99e1e'::uuid,'2026-05-20T15:00:03.606041+05:30'::timestamptz),
    ('71ddd4b2-dd0f-4547-8da6-d4d6358cbfd4'::uuid,'2026-05-25T15:00:02.363468+05:30'::timestamptz),
    ('29f5f551-6d75-4222-807a-a6bc02db79f1'::uuid,'2026-06-12T15:00:02.219603+05:30'::timestamptz),
    ('fd308e29-6527-4d8d-8b7b-25fb08398bf4'::uuid,'2026-06-28T15:00:02.513978+05:30'::timestamptz),
    ('79ed1844-5dff-45a4-bebe-4903d5c44aa0'::uuid,'2026-06-08T15:00:02.742264+05:30'::timestamptz),
    ('9b713925-d712-4d43-bf90-208c45eef345'::uuid,'2026-07-16T15:00:03.162545+05:30'::timestamptz),
    ('a1df1344-1a15-46a9-bd75-4c60421da642'::uuid,'2026-08-02T15:00:01.729657+05:30'::timestamptz),
    ('bb245f0b-205d-4788-9a9c-3dca41c8ab13'::uuid,'2026-05-17T15:00:03.108525+05:30'::timestamptz),
    ('f508d9b8-57ac-44cf-9342-cf07d09acf1e'::uuid,'2026-06-27T15:00:03.230173+05:30'::timestamptz),
    ('33e20fe1-7a42-41b2-a7f6-2a9c84f97138'::uuid,'2026-06-13T15:00:02.523889+05:30'::timestamptz),
    ('a124c843-e612-4f92-a18f-e198a5bfb2e4'::uuid,'2026-08-06T15:00:01.639557+05:30'::timestamptz),
    ('b7e76855-2db2-4fa0-8c12-af9001640a60'::uuid,'2026-07-05T15:00:02.971902+05:30'::timestamptz),
    ('a4053338-cbae-4a79-b6ab-d19edd4e09fa'::uuid,'2026-06-29T15:00:03.733185+05:30'::timestamptz),
    ('594b2253-4f0b-4091-83df-4f881f308df6'::uuid,'2026-07-23T15:00:01.440798+05:30'::timestamptz),
    ('ec2a93e9-afff-4f36-b7ab-3a3a083cbe63'::uuid,'2026-07-26T15:00:01.617838+05:30'::timestamptz),
    ('587a5787-ac4c-4a65-a1f4-51cf970d94a1'::uuid,'2026-06-08T15:00:02.541208+05:30'::timestamptz),
    ('4735bfad-1850-40be-90a5-2f8b4faf4c0c'::uuid,'2026-07-27T15:00:01.460839+05:30'::timestamptz),
    ('e9b077b9-3117-4946-a190-1f4fe166e5a9'::uuid,'2026-06-07T15:00:03.215352+05:30'::timestamptz),
    ('a28280b3-bd87-4136-91c5-34ea176f3b99'::uuid,'2026-06-21T15:00:02.854503+05:30'::timestamptz),
    ('a660498c-15a6-4f7d-8fee-da9163c62ec3'::uuid,'2026-06-28T15:00:04.006896+05:30'::timestamptz),
    ('fbc2d4d0-9f7a-4b0c-9a43-835e403d4ecf'::uuid,'2026-08-05T15:00:01.549533+05:30'::timestamptz),
    ('2850b6c9-4a7e-466d-a9bc-69c93be335fd'::uuid,'2026-06-03T15:00:01.723833+05:30'::timestamptz),
    ('9a83bc03-dffb-4b6c-8747-4aab7224435d'::uuid,'2026-07-09T15:00:02.391032+05:30'::timestamptz),
    ('f0202e5a-129a-4075-8b9a-cd766c87c7d5'::uuid,'2026-05-22T15:00:02.628047+05:30'::timestamptz),
    ('7a088edb-2622-4cae-a109-18d86f4c866c'::uuid,'2026-08-01T15:00:01.161453+05:30'::timestamptz),
    ('415cdd68-793b-4d2a-9248-b416114a35b6'::uuid,'2026-07-20T15:00:01.205029+05:30'::timestamptz),
    ('5ea725c0-ce57-4215-b4bf-624a0930f9f9'::uuid,'2026-05-25T15:00:02.160464+05:30'::timestamptz),
    ('bce3f239-601a-463e-9172-ff0eb1ec24eb'::uuid,'2026-08-04T15:00:01.512635+05:30'::timestamptz),
    ('479c0a01-33ee-4ae8-80ed-f377ffa7f316'::uuid,'2026-06-30T15:00:02.279467+05:30'::timestamptz),
    ('4cc13197-7772-4829-8cc1-1335d7c10c7c'::uuid,'2026-08-10T15:00:02.354534+05:30'::timestamptz),
    ('b1307323-be79-4eb4-9d0b-5dd1efe82b39'::uuid,'2026-07-04T15:00:02.830761+05:30'::timestamptz),
    ('b4501d7f-d9c2-4247-ba94-c638385beb3a'::uuid,'2026-06-06T15:00:02.519684+05:30'::timestamptz),
    ('f962a871-7e57-4a83-9da9-126ddaf8bff5'::uuid,'2026-07-30T15:00:02.250866+05:30'::timestamptz),
    ('09ab6660-8fdf-4403-9333-f7800ce8d191'::uuid,'2026-06-01T15:00:03.755898+05:30'::timestamptz),
    ('0393fe51-8d4c-4066-a37c-0044cb6bf308'::uuid,'2026-07-03T15:00:07.489628+05:30'::timestamptz),
    ('7b1b85a6-cd71-4806-b1d1-d3708110efb9'::uuid,'2026-08-01T15:00:00.955253+05:30'::timestamptz),
    ('3b5c0637-3479-4809-a72c-46207eb35b26'::uuid,'2026-08-10T15:00:02.121296+05:30'::timestamptz),
    ('2321e49d-99e6-488b-9e96-1e30455d51db'::uuid,'2026-07-30T15:00:01.413102+05:30'::timestamptz),
    ('6c9a6e28-df12-432d-8d3b-83d80ff42b5f'::uuid,'2026-07-19T15:00:01.975115+05:30'::timestamptz),
    ('c687d29c-95ac-4249-9fc6-ee5383ae8594'::uuid,'2026-06-27T15:00:02.863714+05:30'::timestamptz),
    ('659e6fa9-9c5e-4135-9d27-472a232341aa'::uuid,'2026-07-19T15:00:01.501341+05:30'::timestamptz),
    ('38bb8b14-e972-4bfe-85f6-76cb5aea9c74'::uuid,'2026-06-02T15:00:02.054149+05:30'::timestamptz),
    ('97fee1f7-2e9d-4109-97a0-6adb9198d37e'::uuid,'2026-05-25T15:00:01.96003+05:30'::timestamptz),
    ('f91d22a7-f518-4d56-877d-5a78f2583817'::uuid,'2026-06-28T15:00:03.333416+05:30'::timestamptz),
    ('fb9cb11c-6bcf-45df-93a0-341f8df63211'::uuid,'2026-07-22T15:00:01.646008+05:30'::timestamptz),
    ('67c13e6a-d394-4dc0-bc5f-3e02bccb9d36'::uuid,'2026-08-04T15:00:01.696088+05:30'::timestamptz),
    ('883a0dad-4791-4a74-b45c-f7a300ec3bdd'::uuid,'2026-08-03T15:00:01.142277+05:30'::timestamptz),
    ('19d06aea-6ab2-402c-955b-9cc05495d109'::uuid,'2026-06-11T15:00:02.450573+05:30'::timestamptz),
    ('974b907f-43a7-4e09-a308-a5fc78e83a61'::uuid,'2026-05-18T15:00:04.016927+05:30'::timestamptz),
    ('0cf4470a-1caf-4672-9adc-839c993fa9ec'::uuid,'2026-08-04T15:00:01.896983+05:30'::timestamptz),
    ('d825b1c8-b3e9-4e0a-8d21-98d4dd5da2b2'::uuid,'2026-08-09T15:00:03.523929+05:30'::timestamptz),
    ('fc39f65c-0582-4dd0-8302-4ca5a36bfedd'::uuid,'2026-06-09T15:00:03.32886+05:30'::timestamptz),
    ('349c024b-3a65-46c3-bcc3-6cc79a137d19'::uuid,'2026-05-28T15:00:03.251126+05:30'::timestamptz),
    ('11b3b308-827b-4768-a0e4-4d6481d91345'::uuid,'2026-06-19T15:00:01.829213+05:30'::timestamptz),
    ('07f0aacf-b305-40bb-95fc-e2f203036805'::uuid,'2026-06-01T15:00:02.542783+05:30'::timestamptz),
    ('62a82595-3704-49e8-834e-118b53d188c3'::uuid,'2026-07-07T15:00:02.844541+05:30'::timestamptz),
    ('0f54056e-032b-4f36-991a-87ebde610914'::uuid,'2026-06-12T15:00:02.424747+05:30'::timestamptz),
    ('2a2860a5-1bce-4f8d-a7ff-5070ba02c366'::uuid,'2026-06-04T15:00:03.455111+05:30'::timestamptz),
    ('44115c07-3809-4550-9b85-0d54194e79b5'::uuid,'2026-07-13T15:00:02.533834+05:30'::timestamptz),
    ('f20b3cf7-f3a5-44c5-b9f5-430cc1158890'::uuid,'2026-07-08T15:00:02.424048+05:30'::timestamptz),
    ('d4eeacc6-a0a2-4b72-bdd7-65d962faac3a'::uuid,'2026-07-11T15:00:04.071105+05:30'::timestamptz),
    ('dc4f262e-8942-41a0-a658-b77e8f576da7'::uuid,'2026-07-06T15:00:02.96571+05:30'::timestamptz),
    ('06d5f1a0-be42-4220-a955-a31b4a0e5908'::uuid,'2026-07-27T15:00:01.645749+05:30'::timestamptz),
    ('fd1138ab-83bf-43ea-846e-f5232a49a672'::uuid,'2026-06-11T15:00:02.855195+05:30'::timestamptz),
    ('80775a85-0b06-45ed-abb9-21c1dbeaa4f2'::uuid,'2026-05-20T15:00:03.405692+05:30'::timestamptz),
    ('b834b866-4530-43ef-9688-678aaee84b23'::uuid,'2026-07-04T15:00:03.030867+05:30'::timestamptz),
    ('ded92a22-cc88-4bef-a816-5657bc4569a5'::uuid,'2026-07-07T15:00:02.645831+05:30'::timestamptz),
    ('1fe5fd32-d914-49a3-aeec-aa51255380ba'::uuid,'2026-05-18T15:00:02.807331+05:30'::timestamptz),
    ('38dde2bb-b025-4466-a551-81cfe32e4a21'::uuid,'2026-07-01T15:00:02.941587+05:30'::timestamptz),
    ('01f5a59c-eaa4-4458-bba0-f4f73d6753a8'::uuid,'2026-06-11T15:00:03.865187+05:30'::timestamptz),
    ('b9bcb08a-47a6-495e-8cbf-659aa897fcd3'::uuid,'2026-07-12T15:00:02.01656+05:30'::timestamptz),
    ('2660eb52-cd42-4e6c-abc6-669fd667eede'::uuid,'2026-06-04T15:00:03.252611+05:30'::timestamptz),
    ('f81b0763-07a1-44bb-9f1e-b97fd6370746'::uuid,'2026-05-24T15:00:03.31578+05:30'::timestamptz),
    ('fee99bc5-0832-4cee-9f2d-6c4e8160833e'::uuid,'2026-06-23T15:00:02.35793+05:30'::timestamptz),
    ('7161591a-1851-4eee-82d1-38e100452dd1'::uuid,'2026-06-25T15:00:02.57267+05:30'::timestamptz),
    ('5a45487a-280c-4949-869f-cf22a0500e00'::uuid,'2026-06-09T15:00:02.924755+05:30'::timestamptz),
    ('83872ee1-f5d6-404c-88a8-3118a7a5205e'::uuid,'2026-07-04T15:00:03.661729+05:30'::timestamptz),
    ('2591ee42-8b5e-483d-b7c2-5f51db617110'::uuid,'2026-08-06T15:00:01.442574+05:30'::timestamptz),
    ('b9a44808-18c1-47c3-a7cb-fbb494bdbe88'::uuid,'2026-06-06T15:00:01.913479+05:30'::timestamptz),
    ('f24efa21-e2c7-45d8-9d03-a19674b53a26'::uuid,'2026-06-06T15:00:03.730946+05:30'::timestamptz),
    ('341a1bf5-c94b-413f-a9d8-cefec30d6c59'::uuid,'2026-07-09T15:00:01.974834+05:30'::timestamptz),
    ('17c7a36c-4501-47a6-aaec-34304f1402ae'::uuid,'2026-06-20T15:00:02.123997+05:30'::timestamptz),
    ('2f79af65-f618-4a3c-85fb-5f9533ed602b'::uuid,'2026-05-23T15:00:02.041641+05:30'::timestamptz),
    ('98114135-24e9-41a2-9364-d9b5486f8b05'::uuid,'2026-06-02T15:00:01.875269+05:30'::timestamptz),
    ('95c9b460-ba36-4e30-be59-c50457661fe0'::uuid,'2026-06-28T15:00:03.123209+05:30'::timestamptz),
    ('7ea31c5f-4864-4217-a138-e17417985f48'::uuid,'2026-06-14T15:00:02.912814+05:30'::timestamptz),
    ('9dc328c6-1169-408f-8a02-d700cdf99db7'::uuid,'2026-05-22T15:00:02.995234+05:30'::timestamptz),
    ('41b605c3-6563-49e9-b6a9-a1e5fc6bc6f8'::uuid,'2026-06-26T15:00:02.471278+05:30'::timestamptz),
    ('b1380e73-dc93-4288-b135-c7e69a63c834'::uuid,'2026-06-09T15:00:03.531408+05:30'::timestamptz),
    ('c51514eb-1d3c-4a5a-bf6d-855e88a94c41'::uuid,'2026-05-30T15:00:03.689566+05:30'::timestamptz),
    ('5b8c1cd7-2eea-4ff9-b394-8fc278d76299'::uuid,'2026-05-27T15:00:02.980416+05:30'::timestamptz),
    ('aaec02e5-d64f-4e0d-84b3-b2e3b6403e82'::uuid,'2026-07-11T15:00:04.643082+05:30'::timestamptz),
    ('8bf167d8-157f-4b4b-959c-49c3c4409bc3'::uuid,'2026-05-18T15:00:03.613733+05:30'::timestamptz),
    ('50bd8dd2-de49-4bb9-b6b2-218e4ec5de1c'::uuid,'2026-07-25T15:00:01.711366+05:30'::timestamptz),
    ('d33544ff-e423-4c58-9130-04dee967c959'::uuid,'2026-05-29T15:00:02.343168+05:30'::timestamptz),
    ('7e662927-7a4e-42a2-9162-f6dee7091bf5'::uuid,'2026-05-28T15:00:03.65143+05:30'::timestamptz),
    ('71c2ddaa-77b2-40bb-9938-be8a215d6676'::uuid,'2026-06-19T15:00:02.285153+05:30'::timestamptz),
    ('6ed202bb-f44d-4c3b-9b33-3529d5cde26e'::uuid,'2026-06-21T15:00:02.020367+05:30'::timestamptz),
    ('8e740688-96f5-43a0-9fed-f8c5f5dd486a'::uuid,'2026-07-22T15:00:00.809838+05:30'::timestamptz),
    ('53008896-1c15-4252-b429-e769e06db01d'::uuid,'2026-06-29T15:00:02.893926+05:30'::timestamptz),
    ('168a5db7-5eae-4f60-abc9-f5d0e027d735'::uuid,'2026-07-22T15:00:01.41899+05:30'::timestamptz),
    ('9150f088-968f-4551-a09e-64a19c9b5f6a'::uuid,'2026-05-27T15:00:03.185885+05:30'::timestamptz),
    ('90feb34c-501b-4c7f-b29f-941e907f7d02'::uuid,'2026-05-19T15:00:03.229821+05:30'::timestamptz),
    ('6dad431a-f838-4cac-a6eb-a974786d4871'::uuid,'2026-07-09T15:00:04.234593+05:30'::timestamptz),
    ('3dd61b97-db68-4b9b-bbd5-e1ca6e0aa3bc'::uuid,'2026-08-06T15:00:02.274328+05:30'::timestamptz),
    ('38f49520-10d3-4b6f-bfca-94bfc652c077'::uuid,'2026-07-01T15:00:02.303238+05:30'::timestamptz),
    ('bd88622b-22f6-4458-955e-bc7a4f624a85'::uuid,'2026-05-17T15:00:02.70732+05:30'::timestamptz),
    ('d903daf6-a01a-474d-8e15-a2d5341bb891'::uuid,'2026-07-16T15:00:02.323631+05:30'::timestamptz),
    ('d4a8d386-0827-48e6-87b6-d7d19c4aa222'::uuid,'2026-06-24T15:00:02.018064+05:30'::timestamptz),
    ('f0f3c04b-a8a8-4ce1-970d-67f7f9dee8d5'::uuid,'2026-06-12T15:00:02.016805+05:30'::timestamptz),
    ('16720eff-608b-4d12-bec2-71fbbbdcb68d'::uuid,'2026-07-09T15:00:02.191233+05:30'::timestamptz),
    ('9668cfb0-7edb-4cf5-8703-4af619cd439a'::uuid,'2026-05-19T15:00:03.836229+05:30'::timestamptz),
    ('ef7eb916-9ff4-431a-ae4c-e85ff7bc55ea'::uuid,'2026-06-29T15:00:02.693118+05:30'::timestamptz),
    ('07684981-4ad2-4ba6-8f80-3f3ac21db22c'::uuid,'2026-05-19T15:00:02.826931+05:30'::timestamptz),
    ('b8a0cea4-593f-4c26-bbc3-ef44bc3bb69f'::uuid,'2026-07-11T15:00:03.023938+05:30'::timestamptz),
    ('b8d7876d-281b-4b91-8d9e-5e1af1e4cfd0'::uuid,'2026-05-15T15:00:03.341759+05:30'::timestamptz),
    ('978a8acc-e116-494f-a4a2-82fbf19c9fc6'::uuid,'2026-05-21T15:00:01.905957+05:30'::timestamptz),
    ('c4a45cf5-6ab9-4a65-b5f9-729d1f0dcbcd'::uuid,'2026-06-11T15:00:04.089367+05:30'::timestamptz),
    ('fef32c54-e22c-42c3-92c0-de1b0520669a'::uuid,'2026-07-22T15:00:01.015862+05:30'::timestamptz),
    ('88b7406b-f14d-4bcf-93d9-d56381cd3154'::uuid,'2026-08-09T15:00:02.245281+05:30'::timestamptz),
    ('cb215198-ac5d-4186-9e2f-e450b5377704'::uuid,'2026-06-04T15:00:03.656821+05:30'::timestamptz),
    ('47443f83-cde2-4b06-b541-1dbeb81bc4a7'::uuid,'2026-06-08T15:00:02.332617+05:30'::timestamptz),
    ('f1131a7e-8df2-4378-b072-dbbd8ac5b711'::uuid,'2026-08-03T15:00:00.896171+05:30'::timestamptz),
    ('3e9f6891-f1d5-4bb9-9710-757b420cbce5'::uuid,'2026-05-16T15:00:04.021945+05:30'::timestamptz),
    ('da377553-008e-400b-a1e9-0dd68538de9a'::uuid,'2026-06-11T15:00:03.663459+05:30'::timestamptz),
    ('716de52a-6f90-467e-9679-b351ed2f623b'::uuid,'2026-05-19T15:00:03.433358+05:30'::timestamptz),
    ('162c3388-88c9-4f01-b34c-1b840f21f55b'::uuid,'2026-07-05T15:00:01.896484+05:30'::timestamptz),
    ('b0f70f18-cf45-4ae9-bf1c-65f81a974f4d'::uuid,'2026-06-08T15:00:02.942208+05:30'::timestamptz),
    ('7f4d0f72-ba4c-4e7e-a8d8-9cc6b167ae29'::uuid,'2026-06-16T15:00:02.594815+05:30'::timestamptz),
    ('15786ae8-17c7-4cd3-9626-0d31b37190cf'::uuid,'2026-08-09T15:00:00.99304+05:30'::timestamptz),
    ('c597c9ff-ca95-42a9-9586-2454b0a75e6b'::uuid,'2026-07-25T15:00:01.951588+05:30'::timestamptz),
    ('1d26c637-ee2d-4561-84a0-4e5f95803ba6'::uuid,'2026-06-11T15:00:02.253495+05:30'::timestamptz),
    ('25c9f0d5-f07b-46b4-87e0-58f9371b42a0'::uuid,'2026-07-30T15:00:01.617418+05:30'::timestamptz),
    ('7fe62f55-c67a-4330-9bdf-66b9e384b992'::uuid,'2026-05-29T15:00:02.535054+05:30'::timestamptz),
    ('42f936cc-33e2-4bc4-add4-ef5a8e556284'::uuid,'2026-06-25T15:00:02.123172+05:30'::timestamptz),
    ('0f89b6d4-8e75-45c2-b0a1-3ae8389d47e9'::uuid,'2026-07-13T15:00:02.329395+05:30'::timestamptz),
    ('7cafb047-1b8e-4cdb-8d02-d17afcf4bb35'::uuid,'2026-06-20T15:00:01.676809+05:30'::timestamptz),
    ('19793b63-ce06-487f-bc39-cb30b659f2b1'::uuid,'2026-05-22T15:00:03.197674+05:30'::timestamptz),
    ('771d73de-b12b-4b16-8c71-062ef9df5ed8'::uuid,'2026-06-08T15:00:01.938948+05:30'::timestamptz),
    ('821cc5ab-daa4-4335-a1b8-9b3d73b003a2'::uuid,'2026-07-24T15:00:02.023053+05:30'::timestamptz),
    ('b93b55a8-e8bd-4a1a-95a2-d33c744f7fa3'::uuid,'2026-06-06T15:00:03.328531+05:30'::timestamptz),
    ('dfd69991-56a7-451a-950d-58d3bcbbe98e'::uuid,'2026-07-11T15:00:03.225964+05:30'::timestamptz),
    ('8c802056-3968-49c7-99ad-93977ec16130'::uuid,'2026-06-30T15:00:02.490224+05:30'::timestamptz),
    ('794325f4-68a1-4b5d-8230-3b6e2c2c75c4'::uuid,'2026-07-04T15:00:02.429062+05:30'::timestamptz),
    ('aeb6c33f-70c2-42b8-b0a4-60ed452ccc9a'::uuid,'2026-07-10T15:00:02.547879+05:30'::timestamptz),
    ('32cd19f7-42d2-4f0e-8b28-20046b1bcda8'::uuid,'2026-05-30T15:00:02.881202+05:30'::timestamptz),
    ('39638a2b-5c0b-4621-8e7e-ef35311c90ed'::uuid,'2026-08-05T15:00:01.799607+05:30'::timestamptz),
    ('4ef2d88a-3599-427e-bcf8-14b5d923bd31'::uuid,'2026-06-14T15:00:02.682601+05:30'::timestamptz),
    ('7cfd2734-6ff8-400f-ab78-c7cc5a1eaa70'::uuid,'2026-06-11T15:00:02.655848+05:30'::timestamptz),
    ('0242614a-a301-403a-94ce-52e3bfde808b'::uuid,'2026-08-06T15:00:00.925455+05:30'::timestamptz),
    ('cdbd7c84-7df9-438f-80f1-219a66a3c5ab'::uuid,'2026-06-04T15:00:02.265197+05:30'::timestamptz),
    ('485f8e2a-273c-4c56-a55c-f44087b96649'::uuid,'2026-06-02T15:00:02.455276+05:30'::timestamptz),
    ('a9cb0381-cbac-442a-808d-0fdea66b22a5'::uuid,'2026-07-23T15:00:01.014335+05:30'::timestamptz),
    ('6dc2c2e6-e76b-4ea9-b64a-72a6a4001a57'::uuid,'2026-07-18T15:00:01.261026+05:30'::timestamptz),
    ('0ce68310-fbca-429c-9e95-b09e9da90640'::uuid,'2026-06-09T15:00:01.718154+05:30'::timestamptz),
    ('48f187cd-8e30-4dcc-b384-bb352cc41378'::uuid,'2026-07-09T15:00:02.594196+05:30'::timestamptz),
    ('f9194ca8-3d01-4541-82a2-e8076a7556d4'::uuid,'2026-05-23T15:00:02.845758+05:30'::timestamptz),
    ('04f227ce-ee42-4021-a784-73ce9758f825'::uuid,'2026-07-25T15:00:01.510696+05:30'::timestamptz),
    ('7e952022-a46c-45d5-a761-685e6fd167a6'::uuid,'2026-05-04T22:57:11.570671+05:30'::timestamptz),
    ('e5fa5619-f187-401a-a5c7-7f9459737f20'::uuid,'2026-07-22T15:00:01.214525+05:30'::timestamptz),
    ('3ff7a955-5f04-4a27-bdf2-fbe4b82ac52f'::uuid,'2026-05-16T15:00:03.605226+05:30'::timestamptz),
    ('a649f252-2f11-41fd-b6b2-b147aa5e7804'::uuid,'2026-08-10T15:00:01.630624+05:30'::timestamptz),
    ('3764121b-fc7e-4162-b715-90acb01bb23f'::uuid,'2026-07-02T15:00:02.148805+05:30'::timestamptz),
    ('f92925b5-1793-473a-a728-f0f7f35f0a72'::uuid,'2026-06-19T15:00:02.720688+05:30'::timestamptz),
    ('52f1da0e-28a4-4c6a-8bdb-d9fcabd13b90'::uuid,'2026-05-23T15:00:02.243497+05:30'::timestamptz),
    ('9b9f154b-b606-4cbc-ad9c-745bf687cc62'::uuid,'2026-06-26T15:00:02.899555+05:30'::timestamptz),
    ('a3e3409f-834a-40dc-80f1-d8b22229e4a9'::uuid,'2026-07-02T15:00:02.569659+05:30'::timestamptz),
    ('acebb560-888c-4c4c-b88a-0c6fb4cb5e8d'::uuid,'2026-07-05T15:00:02.748939+05:30'::timestamptz),
    ('65db92b0-352c-4cd7-83b2-1a8df1f470da'::uuid,'2026-07-28T15:00:01.362198+05:30'::timestamptz),
    ('545781e9-081e-47b5-a8cb-b82322d29ca4'::uuid,'2026-05-17T15:00:02.312205+05:30'::timestamptz),
    ('6bc32d28-a224-4b2a-b7c6-d5d36b0869f3'::uuid,'2026-07-11T15:00:02.789906+05:30'::timestamptz),
    ('baff7500-afe9-4b01-8634-62199b8a4a7e'::uuid,'2026-05-19T15:00:03.026023+05:30'::timestamptz),
    ('34e0effd-985b-44c7-a345-d580318e7555'::uuid,'2026-08-01T15:00:01.364157+05:30'::timestamptz),
    ('13e19d16-0abe-4516-acb0-66f3ab696e7e'::uuid,'2026-08-09T15:00:01.200399+05:30'::timestamptz),
    ('3af2576c-ecea-436f-899a-24b72c5c774c'::uuid,'2026-07-14T15:00:02.712741+05:30'::timestamptz),
    ('ebb52359-152b-4c4b-a796-1851b2482d6f'::uuid,'2026-08-01T15:00:01.580108+05:30'::timestamptz),
    ('cdd68d7b-481d-481a-b1b9-d08ec50e7dd0'::uuid,'2026-06-28T15:00:02.688123+05:30'::timestamptz),
    ('15fafca5-44d6-46ae-8936-5a7689754d54'::uuid,'2026-07-01T15:00:02.094466+05:30'::timestamptz),
    ('d2427ab5-422d-47e9-ae22-08065cf52bfe'::uuid,'2026-07-06T15:00:02.372189+05:30'::timestamptz),
    ('427bae25-72a6-4ae2-8200-ef50af3c89c6'::uuid,'2026-07-15T15:00:01.90921+05:30'::timestamptz),
    ('35264977-0e0f-4113-b7ba-2febb82370d4'::uuid,'2026-06-04T15:00:02.855624+05:30'::timestamptz),
    ('ee48f5d8-7998-4553-8a0a-778724b9194f'::uuid,'2026-07-16T15:00:01.891259+05:30'::timestamptz),
    ('585573db-c0cd-4354-892f-f921ece49b4f'::uuid,'2026-07-09T15:00:03.807852+05:30'::timestamptz),
    ('405e1539-6baa-4f51-a65d-5c18bd06ea42'::uuid,'2026-06-05T15:00:02.912543+05:30'::timestamptz),
    ('cc496a82-0c2f-42a3-8a84-61e393b91827'::uuid,'2026-06-11T15:00:02.045825+05:30'::timestamptz),
    ('b1713f7d-b50c-4bae-8ed7-53f4a9520499'::uuid,'2026-08-06T15:00:02.488087+05:30'::timestamptz),
    ('10a1a6a4-f9bb-4719-a7f1-3e02fb695d9a'::uuid,'2026-06-21T15:00:03.284165+05:30'::timestamptz),
    ('768cd9ed-645f-4e7d-94bc-291bd5a4d754'::uuid,'2026-08-10T15:00:01.886547+05:30'::timestamptz),
    ('24339c12-5806-4b4c-b46a-eb7c3d170b53'::uuid,'2026-06-27T15:00:02.426944+05:30'::timestamptz),
    ('f139e0b4-8b9a-4354-92c0-29a1f49391c9'::uuid,'2026-07-07T15:00:03.050659+05:30'::timestamptz),
    ('1b34c6f1-bd27-4641-8867-f5cee58c2b80'::uuid,'2026-06-13T15:00:03.537327+05:30'::timestamptz),
    ('2a748baa-f9ef-4dc9-9519-1a498069fa94'::uuid,'2026-05-21T15:00:02.299348+05:30'::timestamptz),
    ('6ce0a5e7-ac79-4577-80a7-ee925ba753b2'::uuid,'2026-07-28T15:00:01.799654+05:30'::timestamptz),
    ('10d55b3b-5744-4d8e-a958-60584a5e5292'::uuid,'2026-06-24T15:00:01.794785+05:30'::timestamptz),
    ('429bab29-a721-4935-a1b8-992320a991f2'::uuid,'2026-05-18T15:00:03.816188+05:30'::timestamptz),
    ('44e11939-b737-4867-acaa-89ebc9fd75ee'::uuid,'2026-07-24T15:00:01.579325+05:30'::timestamptz),
    ('f71f68f2-5031-438a-9c41-4bbec35ac62e'::uuid,'2026-08-08T15:00:01.52137+05:30'::timestamptz),
    ('933e1fd0-0bd8-48d1-9f2e-ef56edb6d745'::uuid,'2026-08-05T15:00:01.348239+05:30'::timestamptz),
    ('38ae3ff4-3999-4399-b944-1c7a2ed9ae68'::uuid,'2026-06-18T15:00:01.890879+05:30'::timestamptz),
    ('a3baa5a4-600d-430a-b5e9-05956a71e688'::uuid,'2026-06-29T15:00:03.515971+05:30'::timestamptz),
    ('bb07b37c-859a-4573-86ca-f54d27584f91'::uuid,'2026-07-21T15:00:01.281465+05:30'::timestamptz),
    ('25d4d2e5-b781-4c99-865c-b037f54fed92'::uuid,'2026-06-13T15:00:02.928263+05:30'::timestamptz),
    ('22e1d7b7-fa10-4f97-86cd-1025fb599cc3'::uuid,'2026-06-09T15:00:02.721673+05:30'::timestamptz),
    ('5d19f13a-e8fa-4dae-a7f8-0eea5c151a1d'::uuid,'2026-05-22T15:00:02.795869+05:30'::timestamptz),
    ('ca3426f8-bc3c-4049-b3f2-4de49631d371'::uuid,'2026-06-20T15:00:01.906084+05:30'::timestamptz),
    ('7bec9de4-d3c6-48cf-a79f-c136036e9512'::uuid,'2026-06-12T15:00:02.829479+05:30'::timestamptz),
    ('c58dab2e-6e8c-4d7f-9436-5f6cac32aba9'::uuid,'2026-07-11T15:00:03.831367+05:30'::timestamptz),
    ('bc0a5b51-fc40-4983-a83c-237655e45b46'::uuid,'2026-07-09T15:00:03.622978+05:30'::timestamptz),
    ('30c646b3-79c9-466f-abab-0399a3fbcd12'::uuid,'2026-07-11T15:00:04.845703+05:30'::timestamptz),
    ('dfc92638-479c-46a4-81ce-8be25e9b9ea5'::uuid,'2026-06-09T15:00:01.917606+05:30'::timestamptz),
    ('9b2a2212-67c0-4802-851f-02cbece08b2a'::uuid,'2026-06-06T15:00:03.127782+05:30'::timestamptz),
    ('5e78f31d-1033-44a3-84e1-4f6ed6907c75'::uuid,'2026-08-08T15:00:01.073035+05:30'::timestamptz);

alter table genalpha.wa_flow_event_details add column if not exists _new_rid bigint;

update genalpha.wa_flow_event_details d
   set _new_rid = r.id
  from _fu_map m
  join public.reminder_events r on r.tenant_id='genalpha' and r.created_at = m.ts
 where m.legacy = d.reminder_event_id;

do $$
declare n int;
begin
  select count(*) into n from genalpha.wa_flow_event_details
   where reminder_event_id is not null and _new_rid is null;
  if n > 0 then raise exception '% flow-event rows lost their reminder link', n; end if;
end $$;

-- The view depends on the column, so it has to come down and go back.
-- Captured from pg_get_viewdef rather than retyped, so the 32-column
-- surface the app and the engine both read cannot drift in the process.
drop view if exists genalpha.whatsapp_flow_events cascade;

alter table genalpha.wa_flow_event_details drop column reminder_event_id;
alter table genalpha.wa_flow_event_details rename column _new_rid to reminder_event_id;

create view genalpha.whatsapp_flow_events with (security_invoker = true) as
 SELECT w.id::text AS id,
    w.step AS flow_step,
    d.legacy_uuid AS student_id,
    NULL::uuid AS admission_id,
    x.reminder_event_id,
    x.payment_link_request_id,
    w.meta ->> 'event_type'::text AS event_type,
    w.meta ->> 'direction'::text AS direction,
    w.meta ->> 'channel'::text AS channel,
    x.parent_phone,
    x.message_kind,
    x.message_body,
    w.meta ->> 'message_id'::text AS message_id,
    w.detail AS status,
    x.status_at,
    (w.meta ->> 'sent_at'::text)::timestamp with time zone AS sent_at,
    (w.meta ->> 'accepted_at'::text)::timestamp with time zone AS accepted_at,
    x.delivered_at,
    (w.meta ->> 'read_at'::text)::timestamp with time zone AS read_at,
    (w.meta ->> 'failed_at'::text)::timestamp with time zone AS failed_at,
    w.meta ->> 'error_code'::text AS error_code,
    x.error_message,
    x.payment_plan,
    x.payment_amount,
    x.payment_months,
    x.payment_from_date,
    x.payment_to_date,
    x.proof_bucket,
    x.proof_path,
    x.provider_payload,
    x.created_by,
    w.at AS created_at
   FROM wa_flow_events w
     LEFT JOIN genalpha.wa_flow_event_details x ON x.flow_event_id = w.id
     LEFT JOIN genalpha.student_details d ON d.member_id = w.member_id
  WHERE w.tenant_id = 'genalpha'::text;

revoke all on genalpha.whatsapp_flow_events from public, anon;
grant select, insert, update, delete on genalpha.whatsapp_flow_events to authenticated, service_role;

create trigger wa_flow_events_iud instead of insert or update or delete
  on genalpha.whatsapp_flow_events for each row execute function genalpha.wa_flow_events_write();

alter table genalpha.wa_flow_event_details
  add constraint wa_flow_event_details_reminder_fk
  foreign key (reminder_event_id) references public.reminder_events(id) on delete set null;

comment on column genalpha.wa_flow_event_details.reminder_event_id is
  'public.reminder_events.id. Was uuid until 2026-08-11zp, which made every flow-event write throw — silently, because the caller swallows its errors.';


-- ------------------------------------------------------------
-- The second reason nothing was ever written
-- ------------------------------------------------------------
-- wa_flow_events_write() reads new.meta. The view has no meta column:
-- it exposes GenAlpha's 32 original columns, and meta is the PLATFORM's
-- jsonb, surfaced only through the nine derived fields (event_type,
-- direction, channel, message_id, error_code and the four timestamps).
--
-- So even with the id types right, every insert would still fail with
-- `record "new" has no field "meta"` — and the caller swallows it. Two
-- independent faults on the same silent path, which is what a swallowed
-- error buys you.
--
-- The trigger now builds meta from the nine fields the view does expose,
-- which is where the view reads them back from anyway.
create or replace function genalpha.wa_flow_events_write()
returns trigger language plpgsql security definer set search_path = genalpha, public as $fn$
declare v_member bigint; v_id bigint; v_meta jsonb;
begin
  if tg_op = 'DELETE' then
    delete from public.wa_flow_events where id = old.id::bigint and tenant_id = 'genalpha';
    return old;
  end if;

  select member_id into v_member from genalpha.student_details where legacy_uuid = new.student_id;

  v_meta := jsonb_strip_nulls(jsonb_build_object(
    'channel',     new.channel,
    'error_code',  new.error_code,
    'message_id',  new.message_id,
    'direction',   new.direction,
    'event_type',  new.event_type,
    'accepted_at', new.accepted_at,
    'sent_at',     new.sent_at,
    'read_at',     new.read_at,
    'failed_at',   new.failed_at));

  if tg_op = 'INSERT' then
    insert into public.wa_flow_events (tenant_id, member_id, step, detail, meta, at)
    values ('genalpha', v_member,
            coalesce(nullif(new.flow_step,''), nullif(new.event_type,''), 'event'),
            new.status, v_meta, coalesce(new.created_at, now()))
    returning id into v_id;

    insert into genalpha.wa_flow_event_details (
      flow_event_id, reminder_event_id, payment_link_request_id, created_by,
      delivered_at, error_message, message_body, message_kind, parent_phone,
      payment_amount, payment_from_date, payment_months, payment_plan,
      payment_to_date, proof_bucket, proof_path, provider_payload, status_at)
    values (v_id, new.reminder_event_id, new.payment_link_request_id, new.created_by,
            new.delivered_at, new.error_message, new.message_body, new.message_kind,
            new.parent_phone, new.payment_amount, new.payment_from_date,
            new.payment_months, new.payment_plan, new.payment_to_date,
            new.proof_bucket, new.proof_path, new.provider_payload, new.status_at);

    new.id := v_id::text;
    return new;
  end if;

  v_id := old.id::bigint;
  update public.wa_flow_events
     set step   = coalesce(nullif(new.flow_step,''), step),
         detail = coalesce(new.status, detail),
         meta   = coalesce(meta,'{}'::jsonb) || v_meta
   where id = v_id and tenant_id = 'genalpha';

  insert into genalpha.wa_flow_event_details (
    flow_event_id, reminder_event_id, payment_link_request_id, created_by,
    delivered_at, error_message, message_body, message_kind, parent_phone,
    payment_amount, payment_from_date, payment_months, payment_plan,
    payment_to_date, proof_bucket, proof_path, provider_payload, status_at)
  values (v_id, new.reminder_event_id, new.payment_link_request_id, new.created_by,
          new.delivered_at, new.error_message, new.message_body, new.message_kind,
          new.parent_phone, new.payment_amount, new.payment_from_date,
          new.payment_months, new.payment_plan, new.payment_to_date,
          new.proof_bucket, new.proof_path, new.provider_payload, new.status_at)
  on conflict (flow_event_id) do update set
    reminder_event_id = excluded.reminder_event_id,
    payment_link_request_id = excluded.payment_link_request_id,
    created_by = excluded.created_by, delivered_at = excluded.delivered_at,
    error_message = excluded.error_message, message_body = excluded.message_body,
    message_kind = excluded.message_kind, parent_phone = excluded.parent_phone,
    payment_amount = excluded.payment_amount, payment_from_date = excluded.payment_from_date,
    payment_months = excluded.payment_months, payment_plan = excluded.payment_plan,
    payment_to_date = excluded.payment_to_date, proof_bucket = excluded.proof_bucket,
    proof_path = excluded.proof_path, provider_payload = excluded.provider_payload,
    status_at = excluded.status_at;

  return new;
end $fn$;

revoke execute on function genalpha.wa_flow_events_write() from public, anon;

-- ------------------------------------------------------------
-- Checks
-- ------------------------------------------------------------
do $$
declare v_student uuid; v_rid bigint; v_id text; n0 int; n int;
begin
  if (select data_type from information_schema.columns
       where table_schema='genalpha' and table_name='wa_flow_event_details'
         and column_name='reminder_event_id') <> 'bigint' then
    raise exception 'reminder_event_id is still not bigint';
  end if;

  -- payment_link_requests.id is a uuid, so the reference to it must stay one
  if (select data_type from information_schema.columns
       where table_schema='genalpha' and table_name='wa_flow_event_details'
         and column_name='payment_link_request_id') <> 'uuid' then
    raise exception 'payment_link_request_id should still be uuid';
  end if;

  -- THE WHOLE POINT: the exact payload the engine sends must now insert.
  -- This is what threw, and what hid the reason for today's fallback.
  select count(*) into n0 from genalpha.whatsapp_flow_events;
  select legacy_uuid into v_student from genalpha.student_details limit 1;
  select max(id) into v_rid from reminder_events where tenant_id='genalpha';

  insert into genalpha.whatsapp_flow_events
    (student_id, reminder_event_id, event_type, direction, parent_phone,
     message_kind, message_body, status, status_at, payment_from_date, created_by)
  values (v_student, v_rid, 'direct_payment_template_fallback', 'system',
          '91[redacted-phone]', 'template', 'probe', 'fallback_to_plan_buttons',
          now(), current_date, 'system_auto')
  returning id into v_id;

  if v_id is null then raise exception 'the flow-event insert still returns nothing'; end if;
  if not exists (select 1 from genalpha.whatsapp_flow_events
                  where id = v_id and reminder_event_id = v_rid
                    and event_type = 'direct_payment_template_fallback') then
    raise exception 'the row does not read back with its reminder link intact';
  end if;

  delete from genalpha.whatsapp_flow_events where id = v_id;
  select count(*) into n from genalpha.whatsapp_flow_events;
  if n <> n0 then raise exception 'the probe left % rows behind', n - n0; end if;

  -- the 2,923 migrated rows must be untouched
  if n0 <> 2923 then raise exception 'flow event count is %, expected 2923', n0; end if;

  raise notice 'flow events can record why a send fell back; % historical rows intact', n0;
end $$;
