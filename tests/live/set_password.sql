-- RakizoraFM live tests — give the test accounts ONE password you choose (it is never written in GitHub or the chat).
-- 1) Replace ضع_كلمة_المرور_هنا below with a strong password (16+ characters), run it in Supabase → SQL Editor.
-- 2) Put the same password in the Claude environment settings as the variable FM_TEST_PASS.
update auth.users set encrypted_password = extensions.crypt('ضع_كلمة_المرور_هنا', extensions.gen_salt('bf')), updated_at = now()
 where email like 'fm.test.%@rakizora.test';
select email from auth.users where email like 'fm.test.%@rakizora.test' order by email;
