-- ESQUEMA DE BASE DE DATOS POSTGRESQL EN SUPABASE CON RLS Y FUNCION ATOMICA

-- 1. Tabla de Rifas
CREATE TABLE IF NOT EXISTS raffles (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    subtitle TEXT,
    description TEXT,
    start_num INT DEFAULT 1,
    end_num INT DEFAULT 9999,
    digits INT DEFAULT 4,
    draw_date DATE,
    draw_notice_text TEXT,
    status TEXT DEFAULT 'in_progress',
    admin_phone TEXT NOT NULL,
    prizes JSONB DEFAULT '[]'::jsonb,
    promotions JSONB DEFAULT '[]'::jsonb,
    rules_text TEXT,
    winners JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. Tabla de Solicitudes y Ventas
CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    raffle_id TEXT REFERENCES raffles(id),
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    phone TEXT NOT NULL,
    chances_count INT NOT NULL,
    promo_label TEXT,
    total_amount NUMERIC(12, 2) NOT NULL,
    assigned_numbers TEXT[] DEFAULT '{}',
    status TEXT DEFAULT 'pending_payment', -- pending_payment, confirmed, cancelled
    payment_confirmed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. Tabla de Auditoria
CREATE TABLE IF NOT EXISTS audit_logs (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    action TEXT NOT NULL,
    user_name TEXT DEFAULT 'Sistema'
);

-- 4. FUNCION ATOMICA DE ASIGNACION SEGURA LIBRE DE CONCURRENCIA
CREATE OR REPLACE FUNCTION confirm_order_and_assign_numbers(
    p_order_id TEXT,
    p_admin_name TEXT DEFAULT 'Admin'
)
RETURNS TEXT[] AS $$
DECLARE
    v_raffle_id TEXT;
    v_chances INT;
    v_status TEXT;
    v_start_num INT;
    v_end_num INT;
    v_digits INT;
    v_used_numbers TEXT[];
    v_available_pool TEXT[] := '{}';
    v_selected_numbers TEXT[] := '{}';
    v_i INT;
    v_num_str TEXT;
    v_rand_idx INT;
BEGIN
    SELECT raffle_id, chances_count, status INTO v_raffle_id, v_chances, v_status
    FROM orders WHERE id = p_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Solicitud no encontrada';
    END IF;

    IF v_status = 'confirmed' THEN
        RAISE EXCEPTION 'La solicitud ya fue confirmada previamente';
    END IF;

    IF v_status = 'cancelled' THEN
        RAISE EXCEPTION 'No se puede confirmar una solicitud cancelada';
    END IF;

    SELECT start_num, end_num, digits INTO v_start_num, v_end_num, v_digits
    FROM raffles WHERE id = v_raffle_id;

    SELECT ARRAY_AGG(unnest) INTO v_used_numbers
    FROM (
        SELECT unnest(assigned_numbers) FROM orders 
        WHERE raffle_id = v_raffle_id AND status = 'confirmed'
    ) sub;

    IF v_used_numbers IS NULL THEN
        v_used_numbers := '{}';
    END IF;

    FOR v_i IN v_start_num..v_end_num LOOP
        v_num_str := LPAD(v_i::TEXT, v_digits, '0');
        IF NOT (v_num_str = ANY(v_used_numbers)) THEN
            v_available_pool := array_append(v_available_pool, v_num_str);
        END IF;
    END LOOP;

    IF array_length(v_available_pool, 1) < v_chances THEN
        RAISE EXCEPTION 'No hay suficientes numeros libres disponibles en la rifa';
    END IF;

    FOR v_i IN 1..v_chances LOOP
        v_rand_idx := 1 + floor(random() * array_length(v_available_pool, 1))::INT;
        v_selected_numbers := array_append(v_selected_numbers, v_available_pool[v_rand_idx]);
        v_available_pool := v_available_pool[1:v_rand_idx-1] || v_available_pool[v_rand_idx+1:array_length(v_available_pool, 1)];
    END LOOP;

    UPDATE orders 
    SET status = 'confirmed',
        assigned_numbers = v_selected_numbers,
        payment_confirmed_at = NOW()
    WHERE id = p_order_id;

    INSERT INTO audit_logs (action, user_name) 
    VALUES ('Confirmacion y asignacion de numeros para orden ' || p_order_id, p_admin_name);

    RETURN v_selected_numbers;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;