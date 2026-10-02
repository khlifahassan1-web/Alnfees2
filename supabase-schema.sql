-- ============================================================
-- حسابات المعمل — قاعدة بيانات Supabase
-- الصق هذا الملف بالكامل في: Supabase Dashboard > SQL Editor > New query
-- ثم اضغط RUN. يمكن تشغيله مرة واحدة فقط.
-- ============================================================

-- جدول الملفات الشخصية (يربط كل مستخدم دخول باسمه ودوره)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  role text not null default 'employee' check (role in ('admin','employee')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- عند إنشاء مستخدم جديد في Authentication تلقائيًا يُنشأ له ملف شخصي بدور "موظف"
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username, role)
  values (new.id, split_part(new.email, '@', 1), 'employee');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- دالة مساعدة: هل المستخدم الحالي مدير؟
create or replace function public.is_admin()
returns boolean as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin' and active = true
  );
$$ language sql security definer stable;

-- جدول الشهور (للأرشيف والإغلاق)
create table public.months (
  month_key text primary key,
  closed boolean not null default false,
  closed_at timestamptz,
  closed_by uuid references public.profiles(id)
);

-- جدول العمليات المالية
create table public.transactions (
  id bigint generated always as identity primary key,
  month_key text not null,
  date date not null,
  type text not null check (type in ('income','expense','purchase','salary','transfer')),
  method text not null,
  amount numeric(14,2) not null check (amount > 0),
  category text not null default '',
  note text not null default '',
  created_by uuid references public.profiles(id),
  updated_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_tx_month on public.transactions(month_key);
create index idx_tx_date on public.transactions(date);

-- تفعيل الحماية على مستوى الصفوف
alter table public.profiles enable row level security;
alter table public.months enable row level security;
alter table public.transactions enable row level security;

-- سياسات الملفات الشخصية
create policy "read profiles" on public.profiles for select using (auth.role() = 'authenticated');
create policy "admin update profiles" on public.profiles for update using (public.is_admin());

-- سياسات الشهور
create policy "read months" on public.months for select using (auth.role() = 'authenticated');
create policy "admin insert months" on public.months for insert with check (public.is_admin());
create policy "admin update months" on public.months for update using (public.is_admin());
create policy "admin delete months" on public.months for delete using (public.is_admin());

-- سياسات العمليات المالية
create policy "read tx" on public.transactions for select using (auth.role() = 'authenticated');

create policy "insert tx if month open" on public.transactions for insert with check (
  auth.role() = 'authenticated'
  and not exists (select 1 from public.months m where m.month_key = transactions.month_key and m.closed = true)
);

create policy "admin update tx if month open" on public.transactions for update using (
  public.is_admin()
  and not exists (select 1 from public.months m where m.month_key = transactions.month_key and m.closed = true)
);

-- الحذف: للمدير فقط (مسموح حتى في الشهور المغلقة، لحالات تنظيف الأرشيف)
create policy "admin delete tx" on public.transactions for delete using (public.is_admin());

-- تفعيل المزامنة الفورية (Realtime) على الجدولين
alter table public.transactions replica identity full;
alter table public.months replica identity full;
alter publication supabase_realtime add table public.transactions;
alter publication supabase_realtime add table public.months;

-- ============================================================
-- بعد تشغيل هذا السكربت:
-- 1) من Authentication > Providers > Email: أطفئ "Confirm email"
-- 2) من Authentication > Users > Add user: أنشئ أول حساب مدير
--    البريد: admin@lab.local   (أو أي اسم تختاره + @lab.local)
--    كلمة السر: اختر كلمة قوية
-- 3) بعد إنشائه، من Table Editor > profiles: غيّر role إلى admin لهذا المستخدم
--    (الحساب الأول يُنشأ تلقائيًا بدور employee، لازم ترفعه يدويًا لمرة وحيدة فقط)
-- ============================================================
