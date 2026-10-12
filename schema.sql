-- Litora Books schema. Run once in Supabase > SQL Editor.
create table public.profiles(id uuid primary key references auth.users on delete cascade, name text, email text, mobile text, country text,
  theme text not null default 'system' check(theme in('light','dark','system')), is_suspended boolean not null default false, created_at timestamptz not null default now());
create table public.admins(user_id uuid primary key references auth.users on delete cascade);
create table public.books(id uuid primary key default gen_random_uuid(), title text not null, subtitle text, author text not null, description text,
  category text, tags text[] default '{}', language text default 'English', pages int, price_paise int not null check(price_paise>=0), original_price_paise int,
  cover_path text, file_path text, featured boolean not null default false, status text not null default 'draft' check(status in('draft','published','archived')),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create table public.orders(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  book_id uuid references public.books on delete set null, title text, amount_paise int, status text not null default 'pending' check(status in('pending','paid','rejected','refunded')),
  ref text not null default upper(substr(md5(random()::text),1,8)), created_at timestamptz not null default now());
create table public.audit(id bigserial primary key, admin_id uuid, action text, created_at timestamptz not null default now());

create function public.is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from public.admins where user_id=auth.uid()) $$;

create function public.on_signup() returns trigger language plpgsql security definer set search_path=public as
$$ begin insert into public.profiles(id,email,name) values(new.id,new.email,new.raw_user_meta_data->>'name'); return new; end $$;
create trigger t_signup after insert on auth.users for each row execute function public.on_signup();

-- price comes from the DB, never from the browser; new orders are always pending
create function public.on_order() returns trigger language plpgsql security definer set search_path=public as
$$ declare b public.books; begin
  if tg_op='INSERT' then
    select * into b from books where id=new.book_id and status='published';
    if not found then raise exception 'Book not available'; end if;
    new.title:=b.title; new.amount_paise:=b.price_paise; new.status:='pending'; new.user_id:=auth.uid();
  end if; return new; end $$;
create trigger t_order before insert on public.orders for each row execute function public.on_order();

create function public.on_profile() returns trigger language plpgsql security definer set search_path=public as
$$ begin if not public.is_admin() then new.is_suspended:=old.is_suspended; new.email:=old.email; end if; return new; end $$;
create trigger t_profile before update on public.profiles for each row execute function public.on_profile();

alter table profiles enable row level security; alter table admins enable row level security;
alter table books enable row level security; alter table orders enable row level security; alter table audit enable row level security;

create policy p_prof_sel on profiles for select using(id=auth.uid() or is_admin());
create policy p_prof_upd on profiles for update using(id=auth.uid() or is_admin());
create policy p_books_pub on books for select using(status='published' or is_admin()
  or exists(select 1 from orders o where o.book_id=books.id and o.user_id=auth.uid() and o.status='paid'));
create policy p_books_adm on books for all using(is_admin()) with check(is_admin());
create policy p_ord_sel on orders for select using(user_id=auth.uid() or is_admin());
create policy p_ord_ins on orders for insert with check(user_id=auth.uid() and not exists(select 1 from profiles where id=auth.uid() and is_suspended));
create policy p_ord_adm on orders for update using(is_admin()) with check(is_admin());
create policy p_audit on audit for all using(is_admin()) with check(is_admin());

-- storage: public covers, PRIVATE book files
insert into storage.buckets(id,name,public,file_size_limit) values('covers','covers',true,5242880),('book-files','book-files',false,52428800) on conflict do nothing;
create policy s_cov_r on storage.objects for select using(bucket_id='covers');
create policy s_cov_w on storage.objects for all using(bucket_id='covers' and public.is_admin()) with check(bucket_id='covers' and public.is_admin());
create policy s_bk_adm on storage.objects for all using(bucket_id='book-files' and public.is_admin()) with check(bucket_id='book-files' and public.is_admin());
create policy s_bk_buyer on storage.objects for select using(bucket_id='book-files' and exists(
  select 1 from orders o join books b on b.id=o.book_id where o.user_id=auth.uid() and o.status='paid' and b.file_path=storage.objects.name));

-- make yourself admin: sign up on the site first, then run (with your email):
-- insert into admins select id from auth.users where email='you@example.com';
